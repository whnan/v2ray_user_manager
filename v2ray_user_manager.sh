#!/bin/bash

#====================================================
# V2Ray 用户管理脚本 - 长期可扩展结构
# 适用于 V2Ray + VMess + WS + TLS + Nginx 的服务端
#	System Request:Debian 12
#	Author:	Hn
#	Version: 1.0
#====================================================

CONFIG="/etc/v2ray/config.json"     #<-----你的v2ray配置路径
DOMAIN="www.修改为你的域名"            #<-----你的伪装域名
WS_PATH="/修改为你的路径/"               #<-----你的WS路径
LOGO="====== V2Ray User Manager ======"

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "请使用 root 权限运行脚本"
        exit 1
    fi
}

gen_uuid() {
    uuid=$(cat /proc/sys/kernel/random/uuid)
}

restart_v2ray() {
    systemctl restart v2ray
}

list_users() {
    echo -e "\n当前用户列表："
    jq -r '.inbounds[0].settings.clients[].email' $CONFIG
}

add_user() {
    echo -n "请输入用户名（备注）："
    read remark
    gen_uuid
    limitIp=0

    echo -n "请输入设备上限（0 表示无限制）: "
    read limitIp

    jq ".inbounds[0].settings.clients += [{\"id\":\"$uuid\",\"alterId\":0,\"email\":\"$remark\",\"limitIp\":$limitIp}]" $CONFIG > tmp.$$.json && mv tmp.$$.json $CONFIG

    restart_v2ray

    create_user_link "$uuid" "$remark"
    echo "用户添加成功！"
}

create_user_link() {
    local uid="$1"
    local remark="$2"
    local json="{\"v\":\"2\",\"ps\":\"$remark\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$uid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"$WS_PATH\",\"tls\":\"tls\"}"
    vmess_link="vmess://$(echo -n $json | base64 -w 0)"
    mkdir -p /home/hn/v2ray_user/ulink && echo $vmess_link > /home/hn/v2ray_user/ulink/user_${uid}.link

    echo "配置链接:"
    echo "$vmess_link"

    echo -n "是否生成二维码？ (Y/n): "
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" || "$yz" == "" ]]; then
        install_qr
        echo "=== VMess 配置二维码 ==="
        qrencode -t ANSI "$vmess_link"
        echo "========================="
        echo "VMess 链接：$vmess_link"
        echo "请用 Shadowrocket 扫描上方二维码导入配置。"
    fi
}

install_qr() {
    which qrencode >/dev/null 2>&1 || apt install -y qrencode
}

delete_user() {
    list_users
    echo -n "请输入要删除的 用户名："
    read em
    echo -n "确认删除？ (Y/n): "
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" ]]; then
        jq "del(.inbounds[0].settings.clients[] | select(.email==\"$em\"))" $CONFIG > tmp.$$.json && mv tmp.$$.json $CONFIG
        restart_v2ray
        echo "用户已删除！"
    else
        echo "取消删除操作。"
    fi
}

modify_user() {
    list_users
    echo -n "请输入 用户名: "
    read em
    echo "1) 修改设备上限"
    echo "2) 修改备注"
    echo -n "请选择操作: "
    read opt
    case $opt in
        1)
            echo -n "输入新的设备上限(0 表示无限制): "
            read new_limit
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .limitIp) = $new_limit" \
            $CONFIG > tmp.$$.json && mv tmp.$$.json $CONFIG
            ;;
        2)
            echo -n "输入新备注: "
            read new_remark
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .email) = \"$new_remark\"" \
            $CONFIG > tmp.$$.json && mv tmp.$$.json $CONFIG
            ;;
        *)
            echo "无效选项"
            return
            ;;
    esac
    restart_v2ray
    echo "修改成功！"
}

show_info() {
    list_users
    echo -n "输入 用户名："
    read em

    uid=$(jq -r ".inbounds[0].settings.clients[] | select(.email==\"$em\") | .id" $CONFIG)
    if [ "$uid" == "" ]; then
        echo "找不到该用户!"
        return
    fi
    create_user_link "$uid" "$em"
}

main_menu() {
    clear
    echo "$LOGO"
    echo "1) 添加用户"
    echo "2) 修改用户设置"
    echo "3) 删除用户"
    echo "4) 查看用户配置信息"
    echo "0) 退出"
    echo -n "请选择: "
    read opt
    case $opt in
        1) add_user ;;
        2) modify_user ;;
        3) delete_user ;;
        4) show_info ;;
        0) exit ;;
        *) echo "无效输入";;
    esac
    echo "按任意键返回菜单..."
    read -n 1
    main_menu
}

check_root
main_menu
