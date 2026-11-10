FROM nextcloud:35-apache
# apt-get upgrade : l'image officielle peut avoir du retard sur les correctifs de securite Debian
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
