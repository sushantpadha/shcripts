# 1. Copy home to new partition
sudo rsync -aXS --progress /home/dietcoke/ /mnt/linuxdata/dietcoke/

# 2. Verify the copy looks right
ls -la /mnt/linuxdata/dietcoke/

# 3. Rename old home as backup
sudo mv /home/dietcoke /home/dietcoke.bak

# 4. Create symlink
sudo ln -s /mnt/linuxdata/dietcoke /home/dietcoke

echo "Please delete /home/dietcoke.bak on login"

# 5. Log out and back in, test everything works, then delete backup
#sudo rm -rf /home/dietcoke.bak

