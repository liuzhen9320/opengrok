# Copyright (c) 2018, 2026 Oracle and/or its affiliates. All rights reserved.
# Portions Copyright (c) 2020, Chris Fraire <cfraire@me.com>.

# ==========================================================
# Stage 1: Build OpenGrok Java Artifacts
# ==========================================================
FROM ubuntu:jammy AS build-java

RUN apt-get update && apt-get install --no-install-recommends -y openjdk-21-jdk python3 python3-venv && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /mvn
COPY pom.xml /mvn/
COPY mvnw /mvn/
COPY .mvn /mvn/.mvn
COPY opengrok-indexer/pom.xml /mvn/opengrok-indexer/
COPY opengrok-web/pom.xml /mvn/opengrok-web/
COPY plugins/pom.xml /mvn/plugins/
COPY suggester/pom.xml /mvn/suggester/

RUN sed -i 's:<module>distribution</module>::g' /mvn/pom.xml && \
    sed -i 's:<module>tools</module>::g' /mvn/pom.xml && \
    mkdir -p /mvn/opengrok-indexer/target/jflex-sources && \
    mkdir -p /mvn/opengrok-web/src/main/webapp/js && \
    mkdir -p /mvn/opengrok-web/src/main/webapp/WEB-INF/ && \
    touch /mvn/opengrok-web/src/main/webapp/WEB-INF/web.xml

RUN ./mvnw -DskipTests -Dcheckstyle.skip -Dmaven.antrun.skip package

COPY ./ /opengrok-source
WORKDIR /opengrok-source

RUN /mvn/mvnw -DskipTests=true -Dmaven.javadoc.skip=true -B -V package
RUN /mvn/mvnw help:evaluate -Dexpression=project.version -q -DforceStdout > /mvn/VERSION
RUN cp $(ls -t distribution/target/*.tar.gz | head -1) /opengrok.tar.gz

# ==========================================================
# Stage 2: Build Universal Ctags (Isolate Build Tools)
# ==========================================================
FROM ubuntu:jammy AS build-ctags

RUN apt-get update && apt-get install --no-install-recommends -y \
    git automake build-essential pkg-config libxml2-dev ca-certificates

RUN git clone --depth 1 https://github.com/universal-ctags/ctags.git /root/ctags && \
    cd /root/ctags && ./autogen.sh && ./configure && make -j$(nproc) && make install

RUN ctags --version && which ctags

# ==========================================================
# Stage 3: Final Runtime Image
# ==========================================================
FROM tomcat:10.1.52-jdk21

LABEL maintainer="https://github.com/oracle/opengrok"
LABEL org.opencontainers.image.source="https://github.com/oracle/opengrok"
LABEL org.opencontainers.image.description="OpenGrok code search [fork] - Optimized"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    gnupg2 curl git openssh-client libyaml-dev gosu ca-certificates \
    unzip python3 python3-pip python3-venv python3-setuptools && \
    apt-get purge -y --auto-remove curl gnupg2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 从 Stage 2 复制编译好的 ctags
COPY --from=build-ctags /usr/local/bin/ctags /usr/local/bin/ctags

COPY --from=build-java /opengrok.tar.gz /opengrok.tar.gz
COPY --from=build-java /mvn/VERSION /VERSION

RUN mkdir -p /opengrok /opengrok/etc /opengrok/data /opengrok/src && \
    tar -zxvf /opengrok.tar.gz -C /opengrok --strip-components 1 && \
    rm -f /opengrok.tar.gz && \
    python3 -m venv /venv

ENV PATH=/venv/bin:$PATH

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir /opengrok/tools/opengrok-tools.tar.gz && \
    pip install --no-cache-dir Flask Flask-HTTPAuth waitress && \
    pip uninstall -y pip setuptools wheel

RUN groupadd -g 1111 -r appgroup && useradd -r -g appgroup -u 1111 appuser

ENV SRC_ROOT /opengrok/src
ENV DATA_ROOT /opengrok/data
ENV URL_ROOT /
ENV CATALINA_HOME /usr/local/tomcat
ENV CATALINA_BASE /usr/local/tomcat
ENV CATALINA_TMPDIR /usr/local/tomcat/temp
ENV PATH $CATALINA_HOME/bin:$PATH
ENV CLASSPATH /usr/local/tomcat/bin/bootstrap.jar:/usr/local/tomcat/bin/tomcat-juli.jar
ENV JAVA_OPTS="--add-exports=java.base/jdk.internal.ref=ALL-UNNAMED --add-exports=java.base/sun.nio.ch=ALL-UNNAMED \
--add-exports=jdk.unsupported/sun.misc=ALL-UNNAMED --add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED \
--add-opens=jdk.compiler/com.sun.tools.javac=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED"

COPY docker/logging.properties /usr/local/tomcat/conf/logging.properties
COPY docker/ /scripts

RUN sed -i -e 's/Valve/Disabled/' /usr/local/tomcat/conf/server.xml && \
    chmod +x /scripts/entrypoint.sh /scripts/start.py && \
    chown -R appuser:appgroup /opengrok /scripts

WORKDIR $CATALINA_HOME
EXPOSE 8080

USER appuser

CMD ["/scripts/entrypoint.sh", "/scripts/start.py"]
