{
  # metrics-server's own serving port, matching upstream's default. The pod
  # has its own address, so this does not collide with the kubelet's 10250.
  secure = 10250;
}
