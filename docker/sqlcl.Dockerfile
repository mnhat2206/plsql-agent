FROM eclipse-temurin:17-jre
ARG SQLCL_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends unzip curl \
 && curl -fsSL -o /tmp/sqlcl.zip "https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-${SQLCL_VERSION}.zip" \
 && unzip -q /tmp/sqlcl.zip -d /opt && rm /tmp/sqlcl.zip \
 && apt-get purge -y curl unzip && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
ENV PATH=/opt/sqlcl/bin:$PATH
WORKDIR /work
