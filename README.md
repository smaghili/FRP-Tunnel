# 🚀 FRP Tunnel Manager

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Version](https://img.shields.io/badge/version-1.0.0-orange.svg)

A powerful, user-friendly bash script for managing **Fast Reverse Proxy (FRP)** tunnels on Linux systems. This tool simplifies the process of setting up and managing FRP servers and clients with advanced features.

## ✨ Features

### 🔧 Server Management
- **Multi-Server Support**: Run multiple FRP servers on different ports
- **Auto Protocol Support**: Automatically supports TCP, KCP, QUIC, and WebSocket protocols
- **Web Dashboard**: Built-in web interface for monitoring
- **Advanced Configuration**: High-performance TOML-based configurations

### 📱 Client Management  
- **Easy Setup**: Simple client creation with port ranges support
- **Hot-Reload**: Add/remove ports without service restart (FRP v0.63.0)
- **Protocol Switching**: Change protocols without recreating clients
- **Health Monitoring**: Built-in health checks and diagnostics
- **Complete Log Management**: Advanced log cleaning and management

### 🛠️ Advanced Features
- **Port Range Support**: Configure multiple ports with ranges (e.g., 1000-1300)
- **Mixed Port Lists**: Support for mixed formats (1000-1010,2000,3000-3005)
- **Protocol Selection**: Choose between TCP, QUIC, KCP, and WebSocket
- **Systemd Integration**: Full systemd service management
- **Automatic Cleanup**: Complete log and configuration cleanup
- **Command Shortcut**: Global `frp` command available system-wide

## 🚀 Quick Start

### Installation

1. **Download the script:**
   ```bash
   wget https://github.com/smaghili/FRP-Tunnel/raw/main/main.sh
   chmod +x main.sh
   ```

2. **Run the installer:**
   ```bash
   ./main.sh
   ```
   
3. **Use the global command:**
   ```bash
   frp
   ```

### Basic Usage

1. **Install FRP**: Choose option 1 to download and install FRP binaries
2. **Create Server**: Go to Server Management → Add new server  
3. **Create Client**: Go to Client Management → Add new client
4. **Monitor**: Use log viewing options to monitor your tunnels

## 📋 Supported Protocols

| Protocol | Description | Use Case |
|----------|-------------|----------|
| **TCP** | Traditional, reliable | General purpose |
| **QUIC** | Fast, modern (UDP-based) | Low latency applications |
| **KCP** | Ultra-low latency (UDP-based) | Gaming, real-time apps |
| **WebSocket** | Firewall-friendly | Restricted networks |

## 🔧 Configuration Examples

### Server Configuration
```toml
bindAddr = "0.0.0.0"
bindPort = 7000
auth.method = "token"
auth.token = "your-secret-token"
webServer.port = 7001
```

### Client Configuration  
```toml
serverAddr = "your-server.com"
serverPort = 7000
auth.token = "your-secret-token"
transport.protocol = "tcp"

[[proxies]]
name = "ssh"
type = "tcp"
localPort = 22
remotePort = 22
```

## 🌟 Advanced Features

### Hot-Reload Support
- Add ports to running clients without restart
- Remove ports dynamically
- Protocol switching with automatic service management

### Port Range Configuration
- **Single Port**: `22`
- **Port Range**: `8000-8100`  
- **Mixed Format**: `22,80,8000-8100,9000`

### Complete Log Management
- Automatic systemd journal cleanup
- Service-specific log isolation
- Complete log removal on service deletion

## 📊 System Requirements

- **OS**: Linux (Ubuntu, Debian, CentOS, etc.)
- **Architecture**: x86_64, ARM64, ARM32
- **Dependencies**: systemd, journalctl, wget, tar
- **Privileges**: sudo access required

## 🔒 Security Features

- Token-based authentication
- Configurable web dashboard credentials
- Service isolation with dedicated users
- Automatic log rotation and cleanup

## 🛠️ Troubleshooting

### Common Issues

1. **Service won't start**:
   ```bash
   sudo systemctl status frp-client-yourname
   sudo journalctl -u frp-client-yourname -f
   ```

2. **Port conflicts**:
   - Check if ports are already in use: `netstat -tulpn | grep :PORT`
   - Use different ports for multiple servers

3. **Connection issues**:
   - Verify server is running and accessible
   - Check firewall settings
   - Confirm authentication tokens match

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📧 Support

If you encounter any issues or have questions, please open an issue on GitHub.

---

# 🇮🇷 راهنمای فارسی

## درباره پروژه
ابزار قدرتمند مدیریت تونل‌های FRP برای سیستم‌های لینوکس با امکانات پیشرفته و رابط کاربری ساده.

## ویژگی‌های اصلی
- **مدیریت چند سرور**: اجرای همزمان چندین سرور FRP
- **پشتیبانی کامل پروتکل‌ها**: TCP, QUIC, KCP, WebSocket
- **Hot-Reload**: اضافه/حذف پورت بدون ریستارت سرویس
- **مدیریت لاگ پیشرفته**: پاکسازی کامل لاگ‌ها
- **رابط وب**: داشبورد مدیریتی داخلی

## نصب و راه‌اندازی
```bash
wget https://github.com/smaghili/FRP-Tunnel/raw/main/main.sh
chmod +x main.sh
./main.sh
```

## استفاده
پس از نصب، می‌توانید با دستور `frp` از هر جای سیستم به منوی مدیریت دسترسی داشته باشید.

---

⭐ **اگر این پروژه برایتان مفید بود، ستاره بدهید!** 