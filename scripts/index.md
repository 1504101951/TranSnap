# scripts目录索引

macOS固定签名打包与安装脚本。

1. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
2. [package-and-install-macos.sh](package-and-install-macos.sh)：先强制退出正在运行的 TranSnap，清除构建目录中的旧副本后开始 Release 构建，同时清除本机其余旧副本，再完成固定签名、验签、ZIP，并安装到访达「应用程序」。
