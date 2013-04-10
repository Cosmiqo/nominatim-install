#!/bin/sh
# Script to install Nominatim on Ubuntu
# Tested on 12.04 (View Ubuntu version using 'lsb_release -a') using Postgres 9.1
# http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Ubuntu.2FDebian

# !! Marker #idempotent indicates limit of testing for idempotency - it has not yet been possible to make it fully idempotent.

echo "#\tNominatim installation $(date)"

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "#\tThis script must be run as root." 1>&2
    exit 1
fi

# Bomb out if something goes wrong
set -e

### CREDENTIALS ###
# Name of the credentials file
configFile=.config.sh

# Generate your own credentials file by copying from .config.sh.template
if [ ! -e ./${configFile} ]; then
    echo "#\tThe config file, ${configFile}, does not exist - copy your own based on the ${configFile}.template file." 1>&2
    exit 1
fi

# Load the credentials
. ./${configFile}

# Download url
osmdataurl=http://download.geofabrik.de/openstreetmap/${osmdatafolder}${osmdatafilename}

### MAIN PROGRAM ###

# Logging
# Use an absolute path for the log file to be tolerant of the changing working directory in this script
setupLogFile=$(readlink -e $(dirname $0))/setupLog.txt
touch ${setupLogFile}
echo "#\tImport and index OSM data in progress, follow log file with:\n#\ttail -f ${setupLogFile}"
echo "#\tNominatim installation $(date)" >> ${setupLogFile}

#!! Comments for testing idempotency
if false; then
# Ensure there is a nominatim user account
if id -u ${username} >/dev/null 2>&1; then
    echo "#	User ${username} exists already and will be used."
else
    echo "#	User ${username} does not exist: creating now."

    # Request a password for the Nominatim user account; see http://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
    if [ ! ${password} ]; then
	stty -echo
	printf "Please enter a password that will be used to create the Nominatim user account:"
	read password
	printf "\n"
	printf "Confirm that password:"
	read passwordconfirm
	printf "\n"
	stty echo
	if [ $password != $passwordconfirm ]; then
	    echo "#\tThe passwords did not match"
	    exit 1
	fi
    fi

    # Create the nominatim user
    useradd -m -p $password $username
    echo "#\tNominatim user ${username} created" >> ${setupLogFile}
fi

# Prepare the apt index; it may be practically non-existent on a fresh VM
apt-get update > /dev/null

# Install basic software
apt-get -y install wget git >> ${setupLogFile}

# Install Apache, PHP
echo "\n#\tInstalling Apache, PHP" >> ${setupLogFile}
apt-get -y install apache2 php5 >> ${setupLogFile}

# Install Postgres, PostGIS and dependencies
echo "\n#\tInstalling postgres" >> ${setupLogFile}
apt-get -y install php5-pgsql postgis postgresql php-pear gcc proj libgeos-c1 postgresql-contrib osmosis >> ${setupLogFile}
echo "\n#\tInstalling postgres link to postgis" >> ${setupLogFile}
apt-get -y install postgresql-9.1-postgis postgresql-server-dev-9.1 >> ${setupLogFile}
echo "\n#\tInstalling geos" >> ${setupLogFile}
apt-get -y install build-essential libxml2-dev libgeos-dev libgeos++-dev libpq-dev libbz2-dev libtool automake libproj-dev >> ${setupLogFile}

# Add Protobuf support
echo "\n#\tInstalling protobuf" >> ${setupLogFile}
apt-get -y install libprotobuf-c0-dev protobuf-c-compiler >> ${setupLogFile}

# Temporarily allow commands to fail without exiting the script
set +e

# PHP Pear::DB is needed for the runtime website
# There doesn't seem an easy way to avoid this failing if it is already installed.
pear install DB >> ${setupLogFile}

# Bomb out if something goes wrong
set -e

# Tuning PostgreSQL
./configPostgresql.sh oltp n

# Restart postgres assume the new config
service postgresql restart
#!! Comments for testing idempotency
fi
# We will use the Nominatim user's homedir for the installation, so switch to that
eval cd /home/${username}

# Nominatim software
if [ ! -d "/home/${username}/Nominatim/.git" ]; then
    # Install
    sudo -u ${username} git clone --recursive git://github.com/twain47/Nominatim.git >> ${setupLogFile}
    cd Nominatim
    sudo -u ${username} ./autogen.sh >> ${setupLogFile}
    sudo -u ${username} ./configure --enable-64bit-ids >> ${setupLogFile}
    sudo -u ${username} make >> ${setupLogFile}
else
    # Update
    cd Nominatim
    git pull
fi

# Get Wikipedia data which helps with name importance hinting
# !! These steps take a while and are not necessary during testing of this script
#!! Comments for testing idempotency
#sudo -u ${username} wget --output-document=data/wikipedia_article.sql.bin http://www.nominatim.org/data/wikipedia_article.sql.bin
#sudo -u ${username} wget --output-document=data/wikipedia_redirect.sql.bin http://www.nominatim.org/data/wikipedia_redirect.sql.bin

# http://stackoverflow.com/questions/8546759/how-to-check-if-a-postgres-user-exists
# Creating the importer account in Postgres
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${username}'" | grep -q 1 || sudo -u postgres createuser -s $username

# Create website user in Postgres
websiteUser=www-data
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${websiteUser}'" | grep -q 1 || sudo -u postgres createuser -SDR ${websiteUser}

# Nominatim module reading permissions
chmod +x "/home/${username}"
chmod +x "/home/${username}/Nominatim"
chmod +x "/home/${username}/Nominatim/module"

# Ensure download folder exists
sudo -u ${username} mkdir -p data/${osmdatafolder}

# Download OSM data
sudo -u ${username} wget --output-document=data/${osmdatafolder}${osmdatafilename} ${osmdataurl}

#idempotent
# Cannot make idempotent safely from here because that would require editing nominatim's setup scripts.
# Remove any pre-existing nominatim database
sudo -u postgres psql postgres -c "DROP DATABASE IF EXISTS nominatim"

# Import and index main OSM data
eval cd /home/${username}/Nominatim/
sudo -u ${username} ./utils/setup.php --osm-file /home/${username}/Nominatim/data/${osmdatafolder}${osmdatafilename} --all >> ${setupLogFile}
echo "#\tDone Import and index OSM data $(date)" >> ${setupLogFile}

# Add special phrases
echo "#\tStarting special phrases $(date)" >> ${setupLogFile}
sudo -u ${username} ./utils/specialphrases.php --countries > specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases_countries.sql
sudo -u ${username} ./utils/specialphrases.php --wiki-import > specialphrases.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases.sql
echo "#\tDone special phrases $(date)" >> ${setupLogFile}

# Set up the website for use with Apache
sudo mkdir -m 755 /var/www/nominatim
sudo chown ${username} /var/www/nominatim
sudo -u ${username} ./utils/setup.php --create-website /var/www/nominatim

# Create a VirtalHost for Apache
cat > /etc/apache2/sites-available/nominatim << EOF
<VirtualHost *:80>
        ServerName ${websiteurl}
        ServerAdmin ${emailcontact}
        DocumentRoot /var/www/nominatim
        CustomLog \${APACHE_LOG_DIR}/access.log combined
        ErrorLog \${APACHE_LOG_DIR}/error.log
        LogLevel warn
        <Directory /var/www/nominatim>
                Options FollowSymLinks MultiViews
                AllowOverride None
                Order allow,deny
                Allow from all
        </Directory>
        AddType text/html .php
</VirtualHost>
EOF

# Add local Nominatim settings
localNominatimSettings=/home/nominatim/Nominatim/settings/local.php

cat > ${localNominatimSettings} << EOF
<?php
   // Paths
   @define('CONST_Postgresql_Version', '9.1');
   // Website settings
   @define('CONST_Website_BaseURL', 'http://${websiteurl}/');
EOF

# Change settings file to Nominatim ownership
chown ${username}:${username} ${localNominatimSettings}

# Enable the VirtualHost and restart Apache
a2ensite nominatim
service apache2 reload

echo "#\tNominatim installation completed $(date)" >> ${setupLogFile}
