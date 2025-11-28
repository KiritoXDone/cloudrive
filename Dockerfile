FROM ubuntu:22.04

# Install necessary tools
RUN apt-get update && apt-get install -y \
    tar \
    gzip \
    file \
    jq \
    curl \
    sed \
    && rm -rf /var/lib/apt/lists/*

# Set up a new user named "user" with user ID 1000
RUN useradd -m -u 1000 user

# Switch to the "user" user
USER user

# Set home to the user's home directory
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH

# Set the working directory to the user's home directory
WORKDIR $HOME/Openlist

# Download the latest Openlist release using jq for robustness
RUN curl -sL https://api.github.com/repos/OpenlistTeam/Openlist/releases/latest | \
    jq -r '.assets[] | select(.name | test("linux-amd64.tar.gz$")) | .browser_download_url' | \
    xargs curl -L | tar -zxvf - -C $HOME/Openlist

# Set up the environment
RUN chmod +x $HOME/Openlist/Openlist && \
    mkdir -p $HOME/Openlist/data

# Create data/config.json file with database configuration
RUN echo '{\
    "force": false,\
    "address": "0.0.0.0",\
    "port": ENV_CUSTOM_PORT,\
    "scheme": {\
        "https": false,\
        "cert_file": "",\
        "key_file": ""\
    },\
    "cache": {\
        "expiration": 60,\
        "cleanup_interval": 120\
    },\
    "database": {\
        "type": "mysql",\
        "host": "ENV_MYSQL_HOST",\
        "port": ENV_MYSQL_PORT,\
        "user": "ENV_MYSQL_USER",\
        "password": "ENV_MYSQL_PASSWORD",\
        "name": "ENV_MYSQL_DATABASE"\
    }\
}' > $HOME/Openlist/data/config.json

# Create a startup script that runs Openlist and Aria2
RUN echo '#!/bin/bash\n\
sed -i "s/ENV_MYSQL_HOST/${MYSQL_HOST:-localhost}/g" $HOME/Openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_PORT/${MYSQL_PORT:-3306}/g" $HOME/Openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_USER/${MYSQL_USER:-root}/g" $HOME/Openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_PASSWORD/${MYSQL_PASSWORD:-password}/g" $HOME/Openlist/data/config.json\n\
sed -i "s/ENV_MYSQL_DATABASE/${MYSQL_DATABASE:-Openlist}/g" $HOME/Openlist/data/config.json\n\
sed -i "s/ENV_CUSTOM_PORT/${CUSTOM_PORT:-8080}/g" $HOME/Openlist/data/config.json\n\
$HOME/Openlist/Openlist server --data $HOME/Openlist/data' > $HOME/Openlist/start.sh && \
    chmod +x $HOME/Openlist/start.sh

# Set the command to run when the container starts
CMD ["/bin/bash", "-c", "/home/user/Openlist/start.sh"]

# Expose the default Openlist port
EXPOSE 5244
