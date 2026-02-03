sudo rm -rf backup_db.sh cert config.yaml cron_backup.log data galvanize infra PolyPwnCTF-2025-Challenges zinc zync | true
git clone https://github.com/polycyber/infra
git clone https://github.com/polycyber/PolyPwnCTF-2025-Challenges
cd infra
mv Caddyfile_local Caddyfile
sed -i "s|<server_ip>|192.168.56.105|g" Caddyfile
rm setup.sh
nano setup.sh
chmod +x setup.sh
rm docker-compose.yml
nano docker-compose.yml

./setup.sh --ctfd-url localhost