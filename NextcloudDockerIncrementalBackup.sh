#!/bin/bash
# Script template: Nextcloud docker incremental backup with BorgBackup
# Author: Nils Rau
# E-mail: nrau1990@gmail.com
# https://borgbackup.readthedocs.io/en/stable/
# Prerequesites:
# sudo apt install docker borgbackup moreutils

# TODO: Path to the docker cli binary
dockerBinaryPath="/snap/bin"
# configure runtime environment for cron, append path to docker binary
export PATH=$PATH:$dockerBinaryPath

# TODO: The name of the nextcloud container
nextcloudDockerContainerName='nextcloud'

# TODO: The name of the nextcloud database container
nextcloudDatabaseDockerContainerName='nextcloud-mariadb'

# TODO: The parent directory of your Nextcloud bind mounts
nextcloudBindMountDir='/home/docker/nextcloud'

# TODO: The directory of your Nextcloud data directory (outside the Nextcloud file directory)
# If your data directory is located under Nextcloud's file directory (somewhere in the web root), the data directory should not be a separate part of the backup
nextcloudDataDir=''

# TODO: The directory of the temporary nextcloud database dump
nextcloudDbDumpDir='/tmp/nextcloud_database_dump'

# TODO: The name of the temporary nextcloud database dump
fileNameBackupDb="nextcloud-db.sql"

# TODO: The service name of the web server. Used to start/stop web server (e.g. 'systemctl start <webserverServiceName>')
webserverServiceName='apache2'

# TODO: Your web server user
webserverUser='www-data'

# TODO: The name of the database system (one of: mysql, mariadb, postgresql)
databaseSystem='mariadb'

# TODO: Your Nextcloud database name
nextcloudDatabase='nextcloud'

# TODO: Your Nextcloud database user
dbUser='nextcloud'

# TODO: The password of the Nextcloud database user
dbPassword=''

# TODO: Set the path of the backup destination.
# e.g. backupDestination="/media/nextcloud-backup"
backupDestination="/share/docker-backup/nextcloud/borg"

# TODO: Set the name of the backup repository.
# e.g. repository="borgbackups"
repository=""

# TODO: Set a list of all directories to backup
# e.g. backup="/home/nils/pictures /home/nils/videos --exclude *.tmp"
backup="$nextcloudBindMountDir $nextcloudDbDumpDir"

# TODO: Set the encryption type
# e.g. encryption="repokey-blake2"
# e.g. encryption="none"
encryption="none"

# TODO: Set the compression type
# e.g. compression="none"
compression="lz4"

# TODO: Set the pruning scheme
# This template keeps all backups of the current day, 
# additionally the current archive of the last 7 backup days, 
# the current archive of the last 4 weeks 
# and the current archive of the last 3 months
pruning="--keep-within=1d --keep-daily=7 --keep-weekly=4 --keep-monthly=3"

LogDir="$backupDestination/log"
LogFileName="borg_backup_$(date +"%Y%m%d_%H%M%S").log"
repoPath="$backupDestination"/"$repository"

###################################################################################################

# Function for error messages
errorecho() { cat <<< "$@" 1>&2; }

function DisableMaintenanceMode() {
        echo "Switching off maintenance mode..."
        docker exec --user "${webserverUser}" "${nextcloudDockerContainerName}" php occ maintenance:mode --off
        echo "Done"
        echo
}

# Capture CTRL+C
trap CtrlC INT

function CtrlC() {
        read -p "Backup cancelled. Keep maintenance mode? [y/n] " -n 1 -r
        echo

        if ! [[ $REPLY =~ ^[Yy]$ ]]
        then
                DisableMaintenanceMode
        else
                echo "Maintenance mode still enabled."
        fi

        exit 1
}

# Check for root
#
if [ "$(id -u)" != "0" ]
then
        errorecho "ERROR: This script has to be run as root!"
        exit 1
fi

# Init borg-repo if absent
if [ ! -d "$repoPath" ]; then
  borg init --encryption=$encryption $repoPath
  echo "Borg repository created in $repoPath"
fi

mkdir -p $LogDir
exec > >(ts | tee -i ${LogDir}/${LogFileName})
exec 2>&1

# create temporary dir for nextcloud database dump
mkdir -p $nextcloudDbDumpDir

# Set maintenance mode
#
echo "Set maintenance mode for Nextcloud..."
docker exec --user "${webserverUser}" "${nextcloudDockerContainerName}" php occ maintenance:mode --on
echo "Done"
echo

#
# Stop web server
#
echo "Stopping web server..."
docker exec --user "${webserverUser}" "${nextcloudDockerContainerName}" service "${webserverServiceName}" stop
echo "Done"
echo

#
# Backup DB
#
if [ "${databaseSystem,,}" = "mysql" ] || [ "${databaseSystem,,}" = "mariadb" ]; then
        echo "Creating Nextcloud database dump (MySQL/MariaDB)..."

        if ! [ "$(docker exec "${nextcloudDatabaseDockerContainerName}" bash -c "command -v mysqldump")" ]; then
                errorecho "ERROR: MySQL/MariaDB not installed (command mysqldump not found)."
                errorecho "ERROR: No backup of database possible!"
        else
		docker exec "${nextcloudDatabaseDockerContainerName}" mysqldump -u "${dbUser}"  --password="${dbPassword}" "${nextcloudDatabase}" > "${nextcloudDbDumpDir}/${fileNameBackupDb}"
        fi

        echo "Done"
        echo
elif [ "${databaseSystem,,}" = "postgresql" ]; then
        echo "Creating Nextcloud database dump (PostgreSQL)..."

        if ! [ "$(docker exec "${nextcloudDatabaseDockerContainerName}" bash -c "command -v pg_dump")" ]; then
                errorecho "ERROR:PostgreSQL not installed (command pg_dump not found)."
                errorecho "ERROR: No backup of database possible!"
        else
		docker exec "${nextcloudDatabaseDockerContainerName}" bash -c "export PGPASSWORD="${dbPassword}" ; pg_dump "${nextcloudDatabase}" -U "${dbUser}"" > "${nextcloudDbDumpDir}/${fileNameBackupDb}"
        fi

        echo "Done"
        echo
fi

# backup data
SECONDS=0
echo "Start of backup $(date)."

borg create --compression $compression --exclude-caches --one-file-system -v --stats --progress \
            $repoPath::'{hostname}-{now:%Y-%m-%d-%H%M%S}' $backup

echo "End of backup $(date). Duration: $SECONDS seconds"
echo

# Delete temporary database dump file
#
if [ -f "${nextcloudDbDumpDir}/${fileNameBackupDb}" ]
then
	echo "Deleting Nextcloud database dump file ${nextcloudDbDumpDir}/${fileNameBackupDb}"
 	rm -f "${nextcloudDbDumpDir}/${fileNameBackupDb}"
else
 	echo "Could not locate Nextcloud database dump file ${nextcloudDbDumpDir}/${fileNameBackupDb}"
fi
echo "Done"
echo

# Start web server
#
echo "Starting web server..."
docker exec --user "${webserverUser}" "${nextcloudDockerContainerName}" service "${webserverServiceName}" start
echo "Done"
echo

#
# Disable maintenance mode
#
DisableMaintenanceMode

# prune archives
borg prune -v --list $repoPath --prefix '{hostname}-' $pruning
