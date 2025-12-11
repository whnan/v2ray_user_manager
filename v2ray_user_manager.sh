#!/bin/bash

#====================================================
# V2Ray 用户管理脚本 - 远程一键版 (兼容性修复版)
# 适用于 V2Ray + VMess + WS + TLS + Nginx 的服务端
#   System Request: Debian 12
#   Author: Hn (Fixed for Shell Compatibility)
#   Version: 1.4
#====================================================

# --- 脚本配置存储路径 ---
SCRIPT_CONF="/etc/v2ray_manager.conf"
LOGO="====== V2Ray User Manager ======"

# --- 辅助函数：标准化输出 (解决 echo -e 兼容性问题) ---
info() {
    printf "\033[32m%s\033[0m\n" "$1"
}
warn() {
    printf "\033[33m%s\033[0m\n" "$1"
}
error() {
    printf "\033[31m%s\033[0m\n" "$1"
}
text() {
    printf "%s\n" "$1"
}

# --- 检查 Root 权限 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 权限运行脚本"
        exit 1
    fi
}

# --- 检查必要依赖 (jq, qrencode) ---
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        text "正在安装 jq..."
        apt-get update && apt-get install -y jq
    fi

    if ! command -v qrencode >/dev/null 2>&1; then
        text "正在安装 qrencode..."
        apt-get install -y qrencode
    fi
}

# --- 初始化配置 ---
init_config() {
    if [ -f "$SCRIPT_CONF" ]; then
        # 如果配置文件存在，直接读取
        source "$SCRIPT_CONF"
    else
        warn "首次运行，请配置基本信息："
        
        # 1. 获取 V2Ray 配置文件路径
        printf "请输入 V2Ray 配置文件路径 (回车默认: /etc/v2ray/config.json): "
        read input_config
        
        # 去除可能存在的首尾空格
        input_config=$(echo "$input_config" | xargs)

        if [ -z "$input_config" ]; then
            CONFIG="/etc/v2ray/config.json"
        else
            CONFIG="$input_config"
        fi

        # 打印调试信息，确认路径是否正确
        printf "-> 设定的路径为: \033[36m[%s]\033[0m\n" "$CONFIG"
        
        # 验证文件是否存在
        if [ ! -f "$CONFIG" ]; then
            error "错误：系统找不到文件 [$CONFIG]"
            error "请检查：1.路径是否完全正确 2.V2Ray是否已安装"
            exit 1
        fi

        # 2. 获取域名
        printf "请输入伪装域名 (例如 www.example.com): "
        read DOMAIN
        DOMAIN=$(echo "$DOMAIN" | xargs)

        # 3. 智能获取 WS 路径
        # 使用 jq 提取 path，如果为 null 则返回空
        detected_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$CONFIG")

        if [ -n "$detected_path" ]; then
            printf "-> 检测到配置文件中的 WS 路径: \033[36m%s\033[0m\n" "$detected_path"
            printf "确认使用此路径吗？ (回车确认 / 输入新路径): "
            read input_ws
            input_ws=$(echo "$input_ws" | xargs)
            
            if [ -z "$input_ws" ]; then
                WS_PATH="$detected_path"
            else
                WS_PATH="$input_ws"
            fi
        else
            printf "无法自动获取 WS 路径，请输入 (例如 /ray/): "
            read WS_PATH
            WS_PATH=$(echo "$WS_PATH" | xargs)
        fi

        # 保存配置到本地文件
        echo "CONFIG=\"$CONFIG\"" > "$SCRIPT_CONF"
        echo "DOMAIN=\"$DOMAIN\"" >> "$SCRIPT_CONF"
        echo "WS_PATH=\"$WS_PATH\"" >> "$SCRIPT_CONF"
        
        info "配置已保存至 $SCRIPT_CONF"
        sleep 1
    fi
}

gen_uuid() {
    uuid=$(cat /proc/sys/kernel/random/uuid)
}

restart_v2ray() {
    systemctl restart v2ray
    if [ $? -eq 0 ]; then
        info "V2Ray 重启成功"
    else
        error "V2Ray 重启失败，请检查配置文件格式"
    fi
}

list_users() {
    text ""
    text "当前用户列表："
    jq -r '.inbounds[0].settings.clients[].email // empty' "$CONFIG"
}

add_user() {
    printf "请输入用户名（备注）："
    read remark
    remark=$(echo "$remark" | xargs)
    if [ -z "$remark" ]; then error "用户名不能为空"; return; fi

    gen_uuid
    limitIp=0

    printf "请输入设备上限（0 表示无限制）: "
    read limitIp
    limitIp=${limitIp:-0}

    # 使用临时文件操作，确保安全
    jq ".inbounds[0].settings.clients += [{\"id\":\"$uuid\",\"alterId\":0,\"email\":\"$remark\",\"limitIp\":$limitIp}]" "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"

    restart_v2ray

    create_user_link "$uuid" "$remark"
    info "用户添加成功！"
}

create_user_link() {
    local uid="$1"
    local remark="$2"
    local json="{\"v\":\"2\",\"ps\":\"$remark\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$uid\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"$WS_PATH\",\"tls\":\"tls\"}"
    vmess_link="vmess://$(echo -n "$json" | base64 -w 0)"
    
    mkdir -p /home/hn/v2ray_user/ulink
    echo "$vmess_link" > "/home/hn/v2ray_user/ulink/user_${uid}.link"

    text "-------------------------"
    text "配置链接:"
    text "$vmess_link"
    text "-------------------------"

    printf "是否生成二维码？ (Y/n): "
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" || "$yz" == "" ]]; then
        text "=== VMess 配置二维码 ==="
        qrencode -t ANSI "$vmess_link"
        text "========================="
        text "请用 Shadowrocket / V2RayNG 扫描上方二维码导入配置。"
    fi
}

delete_user() {
    list_users
    printf "请输入要删除的用户名："
    read em
    em=$(echo "$em" | xargs)
    if [ -z "$em" ]; then return; fi

    printf "确认删除 [%s]？ (Y/n): " "$em"
    read yz
    if [[ "$yz" == "Y" || "$yz" == "y" ]]; then
        jq "del(.inbounds[0].settings.clients[] | select(.email==\"$em\"))" "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
        restart_v2ray
        info "用户已删除！"
    else
        text "取消删除操作。"
    fi
}

modify_user() {
    list_users
    printf "请输入用户名: "
    read em
    em=$(echo "$em" | xargs)
    if [ -z "$em" ]; then return; fi

    text "1) 修改设备上限"
    text "2) 修改备注"
    printf "请选择操作: "
    read opt
    case $opt in
        1)
            printf "输入新的设备上限(0 表示无限制): "
            read new_limit
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .limitIp) = $new_limit" \
            "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
            ;;
        2)
            printf "输入新备注: "
            read new_remark
            jq "(.inbounds[0].settings.clients[] | select(.email==\"$em\") | .email) = \"$new_remark\"" \
            "$CONFIG" > tmp.$$.json && mv tmp.$$.json "$CONFIG"
            ;;
        *)
            text "无效选项"
            return
            ;;
    esac
    restart_v2ray
    info "修改成功！"
}

show_info() {
    list_users
    printf "输入用户名："
    read em
    em=$(echo "$em" | xargs)

    uid=$(jq -r ".inbounds[0].settings.clients[] | select(.email==\"$em\") | .id" "$CONFIG")
    if [ "$uid" == "" ] || [ "$uid" == "null" ]; then
        text "找不到该用户!"
        return
    fi
    create_user_link "$uid" "$em"
}

reset_script_config() {
    rm -f "$SCRIPT_CONF"
    info "脚本配置已重置，下次运行将重新询问域名等信息。"
}

main_menu() {
    clear
    text "$LOGO"
    text "当前配置域名: $DOMAIN"
    text "配置文件路径: $CONFIG"
    text "WebSocket路径: $WS_PATH"
    text "-------------------------"
    text "1) 添加用户"
    text "2) 修改用户设置"
    text "3) 删除用户"
    text "4) 查看用户配置信息"
    text "5) 重置本脚本配置 (修改域名/路径)"
    text "0) 退出"
    printf "请选择: "
    read opt
    case $opt in
        1) add_user ;;
        2) modify_user ;;
        3) delete_user ;;
        4) show_info ;;
        5) reset_script_config; exit ;;
        0) exit ;;
        *) text "无效输入";;
    esac
    text "按任意键返回菜单..."
    read -n 1
    main_menu
}

# --- 程序入口 ---
check_root
check_dependencies
init_config
main_menu