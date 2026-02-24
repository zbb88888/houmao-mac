# houmao-mac


## image

```bash


# 创建一个临时目录存放图标集
mkdir houmao.iconset

# 生成所有 macOS 必须的尺寸
sips -z 16 16     AppIcon_1024.png --out houmao.iconset/icon_16x16.png
sips -z 32 32     AppIcon_1024.png --out houmao.iconset/icon_16x16@2x.png
sips -z 32 32     AppIcon_1024.png --out houmao.iconset/icon_32x32.png
sips -z 64 64     AppIcon_1024.png --out houmao.iconset/icon_32x32@2x.png
sips -z 128 128   AppIcon_1024.png --out houmao.iconset/icon_128x128.png
sips -z 256 256   AppIcon_1024.png --out houmao.iconset/icon_128x128@2x.png
sips -z 256 256   AppIcon_1024.png --out houmao.iconset/icon_256x256.png
sips -z 512 512   AppIcon_1024.png --out houmao.iconset/icon_256x256@2x.png
sips -z 512 512   AppIcon_1024.png --out houmao.iconset/icon_512x512.png
cp AppIcon_1024.png houmao.iconset/icon_512x512@2x.png

# 合并成一个 .icns 文件 (可选)
iconutil -c icns houmao.iconset

```
