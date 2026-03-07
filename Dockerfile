ARG PHP_VERSION=8.4
ARG MOODLE_VERSION=5.1.3
ARG MOODLE_MAJOR_VERSION=501

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
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions using mlocati/php-extension-installer
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
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
    redis

# Increase max_input_vars
RUN echo "max_input_vars = 5000" >> /usr/local/etc/php/conf.d/docker-php-moodle.ini

# Set Moodle Version and Download Source
ARG MOODLE_VERSION
ARG MOODLE_MAJOR_VERSION
ENV MOODLE_VERSION=${MOODLE_VERSION}
RUN curl -fSL "https://download.moodle.org/download.php/direct/stable${MOODLE_MAJOR_VERSION}/moodle-${MOODLE_VERSION}.tgz" -o moodle.tgz \
    && tar -xzf moodle.tgz --strip-components=1 -C /var/www/html \
    && rm moodle.tgz \
    && chown -R www-data:www-data /var/www/html

# Create moodledata directory
RUN mkdir -p /var/www/moodledata \
    && chown -R www-data:www-data /var/www/moodledata \
    && chmod -R 777 /var/www/moodledata

WORKDIR /var/www/html

# Copy entrypoint, step scripts, helper scripts and templates
COPY docker-entrypoint.sh /usr/local/bin/
COPY scripts/ /var/www/html/scripts/
COPY entrypoint.d/ /docker-entrypoint.d/
COPY templates/ /var/www/html/templates/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /docker-entrypoint.d/*.sh \
    && chown -R www-data:www-data /var/www/html/scripts /var/www/html/templates /docker-entrypoint.d

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
