The host Docker socket is mounted read-only with respect to metadata changes at
`/var/run/docker-host.sock`. The container always accesses it through the socat
proxy at `/var/run/docker.sock`.

For a rootless host daemon, override the Feature mount with a devcontainer mount
whose source is `/run/user/<host-uid>/docker.sock` and whose target remains
`/var/run/docker-host.sock`.

Possession of a Docker daemon socket normally grants host-root-equivalent
control. Docker Desktop Enhanced Container Isolation can also require an
administrator-approved socket-mount exception.
