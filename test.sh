git clone https://github.com/polycyber/infra
git clone https://github.com/polycyber/PolyPwnCTF-2025-Challenges
cd infra
mv Caddyfile_local Caddyfile
nano Caddyfile
chmod +x setup.sh
./setup.sh --ctfd-url localhost 