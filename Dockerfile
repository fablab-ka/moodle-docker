ARG PHP_VERSION=8.4
ARG MOODLE_VERSION=5.1.3
ARG MOODLE_MAJOR_VERSION=501
ARG MOOSH_GIT_REF=05d93188ac2562b12a739963c1c52d97ca16e70f
ARG ADDITIONAL_APT_PACKAGES=""
ARG ADDITIONAL_PHP_EXTENSIONS=""

FROM php:${PHP_VERSION}-fpm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    unzip \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libpq-dev \
    libxml2-dev \
    libxslt1-dev \
    libz-dev \
    curl \
    gettext-base \
    patch \
    less \
    rsync \
    sudo \
    ${ADDITIONAL_APT_PACKAGES}

# Install PHP extensions using mlocati/php-extension-installer
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
    @composer \
    intl \
    gd \
    zip \
    pgsql \
    pdo_pgsql \
    opcache \
    soap \
    exif \
    bcmath \
    calendar \
    sockets \
    sodium \
    redis \
    ${ADDITIONAL_PHP_EXTENSIONS}

RUN apt-get clean \
    && apt-get distclean

# Create moodle, moosh, moodledata and plugincache directories
RUN mkdir -p /opt/moodle /opt/moosh /var/www/moodledata /var/www/plugincache \
    && chown -R www-data:www-data /opt/moodle /opt/moosh /var/www \
    && chmod -R 755 /opt/moodle /opt/moosh /var/www/moodledata /var/www/plugincache

# Copy entrypoint, step scripts, helper scripts, templates and patches to /opt/moodle
COPY docker-entrypoint.sh /usr/local/bin/
COPY entrypoint.d/ /docker-entrypoint.d/
COPY --chown=www-data:www-data scripts/ /opt/moodle/scripts/
COPY --chown=www-data:www-data templates/ /opt/moodle/templates/
COPY --chown=www-data:www-data patches/ /opt/moodle/patches/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
             /docker-entrypoint.d/*.sh

RUN ln -fs /opt/moosh/moosh.php /usr/local/bin/moosh

# Bake Config and moodle specific PHP settings
COPY --chown=www-data:www-data templates/config.php /opt/moodle/code/config.php
COPY templates/docker-php-moodle.ini /usr/local/etc/php/conf.d/docker-php-moodle.ini

# Change to www-data for correct file permissions
USER www-data

# Install Moosh
RUN cd /opt/moosh \
    && git clone --no-tags --no-checkout -- https://github.com/tmuras/moosh.git ./ \
    && git checkout ${MOOSH_GIT_REF} \
    && rm -r .git \
    && composer -n --no-cache --no-dev -o install

# Set Moodle Version and Download Source
ARG MOODLE_VERSION
ARG MOODLE_MAJOR_VERSION
ENV MOODLE_VERSION=${MOODLE_VERSION}
RUN mkdir -p /opt/moodle/code \
    && cd /opt/moodle/code \
    && curl -fSL "https://download.moodle.org/download.php/direct/stable${MOODLE_MAJOR_VERSION}/moodle-${MOODLE_VERSION}.tgz" -o moodle.tgz \
    && tar -xzf moodle.tgz --no-same-owner --strip-components=1 -C /opt/moodle/code \
    && rm moodle.tgz

# Apply patches to the source of truth
RUN for p in /opt/moodle/patches/*.patch; do \
        [ -e "$p" ] || continue; \
        echo "Applying patch $p"; \
        patch -p0 -d /opt/moodle/code < "$p"; \
    done

# Change back to root
USER root

WORKDIR /var/www/html

# Environment variables with defaults
ENV MOODLE_DB_TYPE=pgsql \
    MOODLE_DB_HOST=db \
    MOODLE_DB_NAME=moodle \
    MOODLE_DB_USER=moodle \
    MOODLE_DB_PASS=moodle \
    MOODLE_DB_PORT=5432 \
    MOODLE_URL=http://localhost \
    MOODLE_REVERSE_PROXY=false \
    MOODLE_SSL_PROXY=false \
    MOODLE_AUTO_UPGRADE=false \
    MOODLE_DISABLE_INSTALL=false \
    MOODLE_ADMIN_USER="" \
    MOODLE_ADMIN_PASS="" \
    MOODLE_ADMIN_EMAIL="" \
    MOODLE_CRON_COUNT=1 \
    MOODLE_ADHOC_TASK_COUNT=0 \
    MOODLE_SITE_FULLNAME="Moodle Site" \
    MOODLE_SITE_SHORTNAME="Moodle" \
    MOODLE_OAUTH2_CONFIG_JSON=""

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
