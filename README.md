# sing-box VLESS-REALITY 一键脚本

用于 Debian / Ubuntu 系统一键部署 **VLESS + TCP + REALITY + Vision** 节点的轻量脚本，全自动配置密钥与守护进程，免配证书。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ljbzbj520/singbox-vless/main/install.sh)
```

提示输入时直接回车即使用默认参数：

* 端口：`443`
* SNI：`www.apple.com`

也可以手动输入自定义值。

## 快捷管理

查看节点信息与 VLESS 分享链接：

```bash
sb
```

查看服务运行状态：

```bash
sb status
```

查看实时连接日志：

```bash
sb log
```

重启节点服务：

```bash
sb restart
```



## 一键卸载

```bash
sb uninstall
```

或者：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ljbzbj520/singbox-vless/main/install.sh) --uninstall
```
