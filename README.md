# Houmao

Houmao is a macOS assistant for fragmented, high-frequency work snippets.

It focuses on tasks that people can usually finish manually within one minute,
but that happen often enough to be worth streamlining: quick information lookup,
translation, summarization, rewriting, extracting action items, and turning copied
content into lightweight notes.

Houmao is intentionally not positioned as a replacement for long-running
professional workflows. Long coding sessions, complex project management,
research pipelines, document authoring, and heavy automation generally deserve
dedicated tools. Houmao is designed for the small gaps between those tools.

## Product Positioning

Houmao helps with:

- quick translation and rewriting of selected text
- short information retrieval and clarification
- summarizing clipboard or selected content
- extracting titles, tags, TODOs, and key points
- saving useful fragments into a notes directory
- lightweight knowledge capture from daily reading and communication

Houmao avoids becoming:

- a full IDE agent
- a general desktop automation platform
- a long-running workflow orchestrator
- a replacement for specialized note-taking, research, or project management apps

## Interaction Model

The intended interaction is small and explicit:

```text
select or copy a fragment
 -> invoke Houmao
 -> ask for a focused action
 -> get a concise result or saved artifact
```

The design goal is to keep the user in flow: Houmao should reduce friction for
fragmented tasks without taking over the whole workflow.

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
