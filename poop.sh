# Create networks
echo "Running: docker network create web\n"
docker network create web
sleep 1
echo "Running: docker network create db\n"
docker network create db
sleep 1

# Create containers on separate networks  
echo "Running: docker run -d --name nginx --network web nginx:latest\n"
docker run -d --name nginx --network web nginx:latest
sleep 1
echo "Running: docker run -d --name postgres --network db postgres:latest\n"
docker run -d --name postgres --network db -e POSTGRES_PASSWORD=password postgres:latest
sleep 1

# Create multi-network container
echo "Running: docker run -d --name app --network web alpine:latest sleep infinity\n"
docker run -d --name app --network web alpine:latest sleep infinity
sleep 1
echo "Running: docker network connect db app\n"
docker network connect db app
sleep 1

# Test DNS resolution
echo "Running: docker exec app nslookup nginx      # Should resolve\n"
docker exec app nslookup nginx      # Should resolve
sleep 1
echo "Running: docker exec app nslookup postgres   # Should resolve\n"
docker exec app nslookup postgres   # Should resolve
sleep 1
echo "Running: docker exec nginx nslookup postgres # Should fail (not on db network)\n"
docker exec nginx nslookup postgres # Should fail (not on db network)
