docker run -d --name test2 alpine sh -c "sleep 3 && echo done";
docker ps          # Shows "Up X seconds";
sleep 4;
docker ps -a       # Should show "Exited (0)";
docker rm test2;
