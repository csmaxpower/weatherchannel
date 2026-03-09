**Hosting:**
- I would like to take this project and host it on my ProxmoxVE server.  I see that it has a Dockerfile ready to go, so I supposed I could install a docker LXC and run the dockerfile on it.  However, if there is a better setup for it (full VM, different LXC for node specific stuff like this, etc. please let me know as option).  
- The internal IP for this host will be 10.30.0.60
- Please detail all necessary deployment steps.
- This will live as a sub-domain under randharris.org as weather.randharris.org
- This will live behind a Traefik proxy for TLS/SSL handling.  Please build a dynamic service yml file I can use in my Traefik deployment.  If I need to supply a current config I can.