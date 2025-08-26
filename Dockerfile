FROM jookies/jasmin:latest

# Copy your custom configs into the container
COPY config/store /etc/jasmin/store
COPY .env /etc/jasmin/.env
COPY config/scripts /opt/jasmin-scripts

# Add entrypoint script (if you want to automate CLI / Telnet config)
# COPY config/entrypoint.sh /entrypoint.sh
# RUN chmod +x /entrypoint.sh

# ENTRYPOINT ["/entrypoint.sh"]

RUN pip install --upgrade pip
COPY config/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Expose ports (if different from default)
EXPOSE 2775