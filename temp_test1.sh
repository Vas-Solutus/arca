docker run -d --name test1 alpine echo "Hello";
sleep 2;
docker ps          # Should be empty;
docker ps -a       # Should show "Exited (0)";
docker rm test1;
