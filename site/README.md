# ExtraWeChat 官网

静态单页站点，无构建步骤、无外部字体、无分析脚本。

## 本地预览

```bash
python3 -m http.server 8000 -d site
open http://localhost:8000
```

## 文件

- `index.html` — 页面内容
- `assets/style.css` — 样式（微信绿）
- `assets/app.js` — 主题切换、滚动动画、截图灯箱
- `assets/screenshots/*.webp` — 界面截图
- `assets/icon-*.png` — App 图标

## 部署到 verlintas.dev/ExtraWeChat/

把 `site/` 目录内容上传到 `verlintas.dev` 的 `/ExtraWeChat/` 路径即可，例如：

```bash
rsync -av --delete site/ user@server:/var/www/verlintas.dev/ExtraWeChat/
```

或者使用 Cloudflare Pages / GitHub Pages：

- **Cloudflare Pages**：构建目录填 `site`，不需要构建命令；
- **GitHub Pages**：把 `site/` 发布到 `gh-pages` 分支，或使用 Pages 的 “Deploy from a branch → /docs” 方式（需要把 `site` 改名为 `docs` 或配置自定义目录）。

> 如果使用自定义域名 `verlintas.dev/ExtraWeChat/`，请确认服务器把该路径指向本目录，
> 并给 `assets/` 设置长期缓存、`index.html` 设置短缓存。

## 内容维护

- 版本号写在 `index.html` 的 hero badge/Release 链接中（当前指向 GitHub Releases latest，不写死版本）；
- 兼容性表在 `index.html` 的 `#compatibility` 和 `docs/COMPATIBILITY.md`；
- 更新截图时替换 `assets/screenshots/*.webp`，保持文件名不变；
- 主题色在 `assets/style.css` 的 `:root` 中修改。
