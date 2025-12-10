#!/bin/bash

#====================================================
# V2Ray 用户管理脚本 - 远程一键版 (智能配置读取)
# 适用于 V2Ray + VMess + WS + TLS + Nginx 的服务端
#   System Request: Debian 12
#   Author: Hn
#   Version: 1.3
#====================================================

# --- 脚本配置存储路径 ---
SCRIPT_CONF="/etc/v2ray_manager.conf"
LOGO="====== V2Ray User Manager ======"

# --- 检查 Root 权限 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "\033[31m请使用 root 权限运行脚本\033[0m"
        exit 1
    fi
}

# --- 检查必要依赖 (jq, qrencode) ---
check_dependencies() {
    local install_needed=0
    
    if ! command -v jq &> /dev/null; then
        echo "正在安装 jq..."
        apt-get update && apt-get install -y jq
    fi

    if ! command -v qrencode &> /dev/null; then
        echo "正在安装 qrencode..."
        apt-get install -y qrencode
    fi
}

# --- 初始化配置 (智能读取版) ---
init_config() {
    if [ -f "$SCRIPT_CONF" ]; then
        # 如果配置文件存在，直接读取
        source "$SCRIPT_CONF"
    else
        echo -e "\033[33m首次运行，请配置基本信息：\033[0m"
        
        # 1. 获取 V2Ray 配置文件路径 (默认值逻辑)
        echo -n "请输入 V2Ray 配置文件路径 (回车默认: /etc/v2ray/config.json): "
        read input_config
        
        if [[ -z "$input_config" ]]; then
            CONFIG="/etc/v2ray/config.json"
        else
            CONFIG="$input_config"
        fi

        echo -e "-> 配置文件路径: \033[36m$CONFIG\033[0m"
        
        # 验证文件是否存在
        if [ ! -f "$CONFIG" ]; then
            echo -e "\033[31m错误：找不到文件 $CONFIG \033[0m"
            echo -e "\033[31m无法自动读取 WS 路径，请确认路径正确。\033[0m"
            exit 1
        fi

        # 2. 获取域名
        echo -n "请输入伪装域名 (例如 www.example.com): "
        read DOMAIN

        # 3. 智能获取 WS 路径
        # 使用 jq 提取 path，如果为 null 则返回空
        detected_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$CONFIG")

        if [[ -n "$detected_path" ]]; then
            echo -e "-> 检测到配置文件中的 WS 路径: \033[36m$detected_path\033[0m"
            echo -n "确认使用此路径吗？ (回车确认 / 输入新路径): "
            read input_ws
            if [[ -z "$input_ws" ]]; then
                WS_PATH="$detected_path"
            else
                WS_PATH="$input_ws"
            fi
        else
            echo -n "无法自动获取 WS 路径，请输入 (例如 /ray/): "
            read WS_PATH
        fi

        # 保存配置到本地文件
        echo "CONFIG=\"$CONFIG\"" > "$SCRIPT_CONF"
        echo "DOMAIN=\"$DOMAIN\"" >> "$SCRIPT_CONF"
        echo "WS_PATH=\"$WS_PATH\"" >> "$SCRIPT_CONF"
        
        echo -e "\033[32m配置已保存至 $SCRIPT_CONF \033[0m"
        sleep 1
    fi
}

gen_uuid() {
    uuid=$(cat /proc/sys/kernel/random/uuid)
}

restart_v2ray() {
    systemctl restart v2ray
    if [ $? -eq 0 ]; then
        echo -e "\033[32mV2Ray 重启成功\033[0m"
    else
        echo -e "\033[31mV2Ray 重启失败，请检查配置文件格式\033[0m"
    fi
}

list_users() {
    echo -e "\n当前用户列表："
    # 使用 jq 安全读取，防止出错
    jq -r '.inbounds[0].settings.clients[].email // empty' "$CONFIG"
}

add_user() {
    echo -n "请输入用户名（备注）："
    read remark
    if [[ -z "$remark" ]]; then echo "用户名不能为空"; return; fi

    gen_uuid
    limitIp=0

    echo -n "请输入设备上限（0 表示无限制）: "
    read limitIp
    limitIp=${limitIp:-0} # 默认为0

    # 使用临时文件操作，确保安全
    jq ".inbounds[0].settings.clients += [{\"id\":\"$uuid\",\"alterId\":0,\"email\":\"$remark\",\"limitIp\":$limitIp}]" "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"

    restart_v2ray

    create_user_link "$uuid" "$remark"
    echo "用户添加成功！"
}

create_user_link() {
    local uid="$1"
    local remark="$2"
    local json="{\"v\":\"2\",\"ps\":\"$remark\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$uid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"$WS_PATH\",\"tls\":\"tls\"}"
    vmess_link="vmess://$(echo -n "$json" | base64 -w 0)"
    
    # 确保存储目录存在
    mkdir -p /home/hn/v2ray_user/ulink
    echo "$vmess_link" > "/home/hn/v2ray_user/ulink/user_${uid}.link"

    echo "-------------------------"
    echo "配置链接:"
    echo "$vmess_link"
    echo "-------------------------"

    echo -n "是否生成二维码？ (Y/n): "
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" || "$yz" == "" ]]; then
        echo "=== VMess 配置二维码 ==="
        qrencode -t ANSI "$vmess_link"
        echo "========================="
        echo "请用 Shadowrocket / V2RayNG 扫描上方二维码导入配置。"
    fi
}

delete_user() {
    list_users
    echo -n "请输入要删除的用户名："
    read em
    if [[ -z "$em" ]]; then return; fi

    echo -n "确认删除 [$em]？ (Y/n): "
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" ]]; then
        jq "del(.inbounds[0].settings.clients[] | select(.email==\"$em\"))" "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
        restart_v2ray
        echo "用户已删除！"
    else
        echo "取消删除操作。"
    fi
}

modify_user() {
    list_users
    echo -n "请输入用户名: "
    read em
    if [[ -z "$em" ]]; then return; fi

    echo "1) 修改设备上限"
    echo "2) 修改备注"
    echo -n "请选择操作: "
    read opt
    case $opt in
        1)
            echo -n "输入新的设备上限(0 表示无限制): "
            read new_limit
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .limitIp) = $new_limit" \
            "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
            ;;
        2)
            echo -n "输入新备注: "
            read new_remark
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .email) = \"$new_remark\"" \
            "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
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
    echo -n "输入用户名："
    read em

    uid=$(jq -r ".inbounds[0].settings.clients[] | select(.email==\"$em\") | .id" "$CONFIG")
    if [ "$uid" == "" ] || [ "$uid" == "null" ]; then
        echo "找不到该用户!"
        return
    fi
    create_user_link "$uid" "$em"
}

reset_script_config() {
    rm -f "$SCRIPT_CONF"
    echo "脚本配置已重置，下次运行将重新询问域名等信息。"
}

main_menu() {
    clear
    echo "$LOGO"
    echo "当前配置域名: $DOMAIN"
    echo "配置文件路径: $CONFIG"
    echo "WebSocket路径: $WS_PATH"
    echo "-------------------------"
    echo "1) 添加用户"
    echo "2) 修改用户设置"
    echo "3) 删除用户"
    echo "4) 查看用户配置信息"
    echo "5) 重置本脚本配置 (修改域名/路径)"
    echo "0) 退出"
    echo -n "请选择: "
    read opt
    case $opt in
        1) add_user ;;
        2) modify_user ;;
        3) delete_user ;;
        4) show_info ;;
        5) reset_script_config; exit ;;
        0) exit ;;
        *) echo "无效输入";;
    esac
    echo "按任意键返回菜单..."
    read -n 1
    main_menu
}

# --- 程序入口 ---
check_root
check_dependencies
init_config
main_menu