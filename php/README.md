# ibroadcast-uploader.php
1. Move this script to the root directory of your music files.

2. Install composer (https://getcomposer.org/download/)
Example code from composer's website, please visit link above for up to date version:
```
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === 'ed0feb545ba87161262f2d45a633e34f591ebb3381f2e0063c345ebea4d228dd0043083717770234ec00c5a9f9593792') { echo 'Installer verified'.PHP_EOL; } else { echo 'Installer corrupt'.PHP_EOL; unlink('composer-setup.php'); exit(1); }"
php composer-setup.php
php -r "unlink('composer-setup.php');"
```

3. Install dependencies
```
php composer.phar install
```

4. Run script
```
php ibroadcast-uploader.php
```