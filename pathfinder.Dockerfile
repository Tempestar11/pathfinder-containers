FROM php:7.4-fpm-alpine AS build

ENV COMPOSER_ALLOW_SUPERUSER=1

RUN set -eux; \
    apk update && apk add --no-cache \
      libpng-dev \
      libjpeg-turbo-dev \
      freetype-dev \
      zeromq-dev \
      git \
      curl \
      ca-certificates \
      pkgconfig \
    ; \
    # install build deps required for pecl/phpize and native compilation
    apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS \
      build-base \
      autoconf \
      automake \
      libtool \
    ; \
    # update PECL channel (silences protocol warnings) and install extensions
    pecl channel-update pecl.php.net || true; \
    pecl install redis && docker-php-ext-enable redis; \
    pecl install zmq-1.1.3 && docker-php-ext-enable zmq; \
    # configure and install PHP extensions (use all CPUs)
    docker-php-ext-configure gd --with-jpeg --with-freetype || true; \
    docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gd pdo_mysql; \
    # install composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; \
    # cleanup build deps and apk cache to keep image small
    apk del .build-deps && rm -rf /var/cache/apk/*

COPY pathfinder /app
WORKDIR /app

RUN composer self-update 2.1.8
RUN composer install

FROM trafex/alpine-nginx-php7:ba1dd422

RUN apk update && apk add --no-cache busybox-suid sudo php7-redis php7-pdo php7-pdo_mysql \
    php7-fileinfo php7-event shadow gettext bash apache2-utils logrotate ca-certificates

# fix expired DST Cert
RUN sed -i '/^mozilla\/DST_Root_CA_X3.crt$/ s/^/!/' /etc/ca-certificates.conf \
    && update-ca-certificates 

# symlink nginx logs to stdout/stderr for supervisord
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

COPY static/logrotate/pathfinder /etc/logrotate.d/pathfinder
COPY static/nginx/nginx.conf /etc/nginx/templateNginx.conf
# we need to create sites_enabled directory in order for entrypoint.sh being able to copy file after envsubst
RUN mkdir -p /etc/nginx/sites_enabled/
COPY static/nginx/site.conf  /etc/nginx/templateSite.conf

# Configure PHP-FPM
COPY static/php/fpm-pool.conf /etc/php7/php-fpm.d/zzz_custom.conf

COPY static/php/php.ini /etc/zzz_custom.ini
# configure cron
COPY static/crontab.txt /var/crontab.txt
# Configure supervisord
COPY static/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY static/entrypoint.sh   /

WORKDIR /var/www/html
COPY  --chown=nobody --from=build /app  pathfinder

RUN chmod 0766 pathfinder/logs pathfinder/tmp/ && rm index.php && touch /etc/nginx/.setup_pass &&  chmod +x /entrypoint.sh
COPY static/pathfinder/routes.ini /var/www/html/pathfinder/app/
COPY static/pathfinder/environment.ini /var/www/html/pathfinder/app/templateEnvironment.ini

WORKDIR /var/www/html
EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
