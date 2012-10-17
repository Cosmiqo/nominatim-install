#!/bin/sh
# The following method of logging output came from: http://serverfault.com/questions/103501/how-can-i-fully-log-all-bash-scripts-actions
#exec 3>&1 4>&2
#trap 'exec 2>&4 1>&3' 0 1 2 3
#exec 1>log.out 2>&1
# Everything below will go to the file 'log.out':

# Script to install Nominatim on Ubuntu
# Tested on 12.04 (View Ubuntu version using 'lsb_release -a') using Postgres 9.1
# http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Ubuntu.2FDebian

echo "#\tNominatim installation"

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

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
	echo "#\tThis script must be run as root" 1>&2
	exit 1
fi

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

echo "#\tPassword: ${password}"

# Create the Nominatim user
useradd -m -p $password $username
echo "#\tNominatim user ${username} created"

# Install basic software
apt-get -y install wget git

# Install Apache, PHP
apt-get -y install apache2 php5

# Install Postgres, PostGIS and dependencies
apt-get -y install php5-pgsql postgis postgresql php5 php-pear gcc proj libgeos-c1 postgresql-contrib git osmosis
apt-get -y install postgresql-9.1-postgis postgresql-server-dev-9.1
apt-get -y install build-essential libxml2-dev libgeos-dev libpq-dev libbz2-dev libtool automake libproj-dev

# Add Protobuf support
apt-get -y install libprotobuf-c0-dev protobuf-c-compiler

# PHP Pear::DB is needed for the runtime website
pear install DB

# We will use the Nominatim user's homedir for the installation, so switch to that
eval cd ~${username}

# Nominatim software
sudo -u ${username} git clone --recursive git://github.com/twain47/Nominatim.git
cd Nominatim
sudo -u ${username} ./autogen.sh
sudo -u ${username} ./configure --enable-64bit-ids
sudo -u ${username} make

# Get Wikipedia data which helps with name importance hinting
# !! These steps take a while and are not necessary during testing of this script
#sudo -u ${username} wget --output-document=data/wikipedia_article.sql.bin http://www.nominatim.org/data/wikipedia_article.sql.bin
#sudo -u ${username} wget --output-document=data/wikipedia_redirect.sql.bin http://www.nominatim.org/data/wikipedia_redirect.sql.bin

# Creating the importer account in Postgres
sudo -u postgres createuser -s $username

# Create website user in Postgres
sudo -u postgres createuser -SDR www-data

# Nominatim module reading permissions
chmod +x "/home/${username}"
chmod +x "/home/${username}/Nominatim"
chmod +x "/home/${username}/Nominatim/module"

# Ensure download folder exists
sudo -u ${username} mkdir -p data/${osmdatafolder}

# Download OSM data
sudo -u ${username} wget --output-document=data/${osmdatafolder}${osmdatafilename} ${osmdataurl}

# Logging
setupLogFile=setupLog.txt
touch ${setupLogFile}
echo "#\tImport and index OSM data in progress, follow log file with: tail -f ${setupLogFile}"
echo "#\tNominatim installation $(date)" >> ${setupLogFile}

# Import and index main OSM data
eval cd /home/${username}/Nominatim/
sudo -u ${username} ./utils/setup.php --osm-file /home/${username}/Nominatim/data/${osmdatafolder}${osmdatafilename} --all >> ${setupLogFile}

# Add special phrases
sudo -u ${username} ./utils/specialphrases.php --countries > specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases_countries.sql
sudo -u ${username} ./utils/specialphrases.php --wiki-import > specialphrases.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases.sql

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
cat > /home/nominatim/Nominatim/settings/local.php << EOF
<?php
   // Paths
   @define('CONST_Postgresql_Version', '9.1');
   // Website settings
   @define('CONST_Website_BaseURL', 'http://${websiteurl}/');
EOF

# Enable the VirtualHost and restart Apache
a2ensite nominatim
service apache2 reload

