#!/usr/bin/env bash

set -o pipefail
pids=()

cleanup() {
    echo "receive SIGTERM, kill ${pids[*]}"
    for pid in "${pids[@]}"; do
        kill "$pid"
        wait "$pid"
    done
}

set_mirror() {
    [ "$IN_CHINA" = true ] || return 0

    if [ -f /etc/apk/repositories ]; then
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/' /etc/apk/repositories
    fi
    if command -v npm >/dev/null 2>&1; then
        npm config set registry https://registry.npmmirror.com/
    fi
    # if command -v composer >/dev/null 2>&1; then
    #     composer config -g repo.packagist composer https://mirrors.aliyun.com/composer
    # fi
}

docker_build() {
    set -xe
    rm -rf /app
    ln -sf $web_dir /app
    ## php setting
    (
        echo "upload_max_filesize=5120M;"
        echo "post_max_size=5120M;"
    ) >>/opt/docker/etc/php/php.ini
    (
        echo "client_max_body_size 5120m;"
    ) >/opt/docker/etc/nginx/vhost.common.d/10-general.conf

    ## fix nginx warning
    sed -i -e '1 s/^/#/' /opt/docker/etc/nginx/vhost.ssl.conf
    sed -i -e '/443\ default_server/s//443\ default_server\ ssl/' /opt/docker/etc/nginx/vhost.conf

    ## disable service
    mv /opt/docker/etc/supervisor.d/cron.conf{,.bak}
    mv /opt/docker/etc/supervisor.d/dnsmasq.conf{,.bak}
    # mv /opt/docker/etc/supervisor.d/nginx.conf{,.bak}
    # mv /opt/docker/etc/supervisor.d/php-fpm.conf{,.bak}
    mv /opt/docker/etc/supervisor.d/postfix.conf{,.bak}
    mv /opt/docker/etc/supervisor.d/ssh.conf{,.bak}
    mv /opt/docker/etc/supervisor.d/syslog.conf{,.bak}

    set_mirror

    apk update
    apk add --update --no-cache nodejs npm sqlite sqlite-dev

    mv $showdoc_dir_html/mock $showdoc_dir/
    cd $showdoc_dir/mock || exit 1
    ## fix old warn
    # rm -f package-lock.json

    npm install
}

backup_dbfile() {
    if [[ "${IN_CHINA}" == true ]]; then
        backup_time="$(TZ='Asia/Shanghai' date +%F-%H-%M-%S)"
    else
        backup_time="$(date +%F-%H-%M-%S)"
    fi
    rsync -a $db_file ${db_file}.backup.full."$backup_time".php
    ## remove old files (15 days ago)
    find ${db_file}.* -type f -ctime +15 -print0 |
        xargs -t -0 rm -f >/dev/null
}

docker_run() {
    ## 首次启动需要拷贝程序文件到 $web_dir/ (/var/www/html)
    if [ -f "$web_dir/index.php" ]; then
        echo "Found $web_dir/index.php, skip copy."
    else
        echo "Not found $web_dir/index.php, copy from $showdoc_dir_html to $web_dir..."
        ## 兼容历史版本 宿主机/showdoc_data/挂载到容器内/showdoc_data_old/
        if [[ -f $showdoc_dir_old/html/index.php && ! -f $showdoc_dir_old/.skip_old ]]; then
            echo "Found old version of \"showdoc_data\", copy..."
            rsync -a $showdoc_dir_old/html/ $web_dir/ &&
                touch $showdoc_dir_old/.skip_old
        else
            rsync -a $showdoc_dir_html/ $web_dir/
        fi
    fi
    echo "Checking upgrade..."
    ## upgrade (通过 Dockerfile 的环境变量 SHOWDOC_DOCKER_VERSION 变更版本)
    ## upgrade (通过 composer.json "version" 变更版本)
    ver_file=$web_dir/.ver
    version_json=$(grep -o '"version":.*"' $showdoc_dir_html/composer.json | awk '{split($2,a,"\""); print a[2]}')
    # version_json=$(grep -o '"version":.*"' $showdoc_dir_html/composer.json | awk '{print substr($2,2,6)}')
    if [ -f $ver_file ]; then
        # if [[ "$SHOWDOC_DOCKER_VERSION" == "$(cat $ver_file)" ]]; then
        if [[ "${version_json}" == "$(cat $ver_file)" ]]; then
            echo "Same version, skip upgrade."
        else
            echo "Backup db file before upgrade..."
            backup_dbfile
            echo "Upgrade application files..."
            ## 此处不同步 db 文件和 upload 文件，自动排除
            rsync -a --exclude='Sqlite/' --exclude='Public/Uploads/' $showdoc_dir_html/ $web_dir/
            ## revert lang if lang=en
            if grep -q 'lang:.*en' $web_dir/web/index.html; then
                sed -i -e "/lang:.*zh-cn.*/s//lang: 'zh-cn'/" $web_dir/web/index.html $web_dir/web_src/index.html
            fi
        fi
    else
        # echo "$SHOWDOC_DOCKER_VERSION" >$ver_file
        echo "$version_json" >$ver_file
    fi

    echo "Checking file permission..."
    ## fix file permission
    # find $web_dir -type f -exec chmod 644 {} \;
    # find $web_dir -type d -exec chmod 755 {} \;
    # find $web_dir -type f -iname '*.sh' -exec chmod 755 {} \;
    runtime_dir="$web_dir/server/Application/Runtime"
    [[ -d $runtime_dir ]] || mkdir -p $runtime_dir
    chown -R 1000:1000 \
        $web_dir/Sqlite \
        $web_dir/Public/Uploads \
        $web_dir/install \
        $runtime_dir
    # 确保 install/ajax.php 中提到的文件有写入权限
    chmod 666 "$web_dir/server/Application/Home/Conf/config.php"
    chmod 666 "$web_dir/web/index.html"
    chmod 666 "$web_dir/web_src/index.html"

    ## backup sqlite file every day / 后台进程每日自动备份数据库
    while [ -f $db_file ]; do
        # backup on (20:01 UTC) (04:01 Asia/Shanghai) every day
        if [[ $(date -u +%H%M) == 2001 ]]; then
            backup_dbfile
            sleep 5
        fi
        sleep 55
    done &
    pids+=("$!")

    ## 启动 showdoc 服务
    echo "Starting showdoc server..."
    (
        sleep 3
        cd $showdoc_dir_html/server || exit 1
        php index.php /api/update/dockerUpdateCode
    )
    ## 延迟启动 mock 服务
    (
        echo "delay 30s start mock..."
        sleep 30
        cd $showdoc_dir/mock/ || exit 1
        npm run start
    ) &
    pids+=("$!")

    ## 启动 supervisor 服务
    echo "Starting nginx and php-fpm..."
    supervisord -c /opt/docker/etc/supervisor.conf &
    pids+=("$!")

    wait
}

main() {
    showdoc_dir='/showdoc_data'
    ## 兼容历史版本的目录
    showdoc_dir_old='/showdoc_data_old'
    ## 包含程序文件
    showdoc_dir_html="$showdoc_dir/html"
    ## web site dir / 网站目录
    web_dir='/var/www/html'
    ## 数据库文件
    db_file=$web_dir/Sqlite/showdoc.db.php

    case $1 in
    -b | --build)
        docker_build
        ;;
    *)
        ## 识别中断信号，停止进程
        trap cleanup HUP INT QUIT TERM

        docker_run
        ;;
    esac
}

main "$@"
