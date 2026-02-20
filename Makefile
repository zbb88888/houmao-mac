.PHONY: clean run build test archive install

# 项目配置
PROJECT := mac/houmao/houmao.xcodeproj
SCHEME := houmao
CONFIGURATION := Debug
APP_NAME := houmao

# 清理：关闭应用 + 清理缓存
clean:
	@echo "🧹 关闭旧应用..."
	@pkill -9 $(APP_NAME) 2>/dev/null || true
	@echo "🧹 清理 Xcode 缓存..."
	@rm -rf ~/Library/Developer/Xcode/DerivedData
	@echo "✅ 清理完成"

# 运行：清理 + 打开 Xcode
run: clean
	@echo "🚀 打开 Xcode..."
	@open $(PROJECT)

# 构建（可选，用于 CI 或命令行构建）
build:
	@echo "🔨 构建项目..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		build

# 构建 Release 版本并安装到 Applications
install:
	@echo "🔨 构建 Release 版本..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		clean build
	@echo "📦 安装到 /Applications..."
	@sudo rm -rf /Applications/$(APP_NAME).app
	@sudo cp -R ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Release/$(APP_NAME).app /Applications/
	@echo "✅ 安装完成！请从 Spotlight 或 Applications 文件夹启动应用"
	@echo "💡 注意：首次启动时需要授予辅助功能权限"

# 运行测试
test:
	@echo "🧪 运行测试..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		test
