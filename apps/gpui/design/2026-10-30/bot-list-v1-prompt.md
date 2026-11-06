# Bot list — imagegen design brief

Tool: built-in imagegen. Output: `bot-list-v1.png`.

The mockup uses a nickname placeholder. The final implementation stores the
user's nickname independently from Bot names. Subsequent user direction replaces
the section-level create actions with a top-right plus menu containing **新建 Bot**
and **发起群聊**.

## Generation prompt

Use case: ui-mockup.
Create a polished high fidelity design board for the existing Rish iOS app's new Bot list page, showing an iPhone portrait screen at left and a genuinely responsive iPad landscape screen at right, both large and legible. This is a product UI mockup for implementation, no illustration, no photographic scene, no marketing headings.
The existing app is an extremely clean almost-white (#F7F7F8) native iOS interface inspired by the user's Codex/Grok references: black text, soft gray secondary type, white floating controls, subtle diffuse shadows, large rounded corners, Lucide-style thin outline icons, restrained blue status dots. Preserve that quiet minimal visual identity. No gradients, no vivid colored panels, no heavy borders or sci-fi aesthetic.
iPhone page: iOS status bar, top left small round user avatar as drawer control, bold page title exactly "Bot", top right small white circular plus button. Below, quiet search pill "搜索 Bot 或群聊". Section "我的 Bot" with action "新建 Bot". A beautiful vertical LIST, not giant cards or a dashboard: three generous rows, each round avatar about 48px, name in black, tiny gray one-line state, subtle chevron. Names exactly "本机验证助手", "工作助手", "生活助手"; state for first "随时待命", second "整理思路，推进工作", third "记住日常，安排生活". Subtle thin separators inset after avatars. Plenty of whitespace; hierarchy very clear and touch friendly. Lower section "群聊", action "发起群聊", one row with overlapping small Bot avatars, title "一起讨论", secondary "3 个 Bot". At bottom plenty of safe area, no bottom tabs, no composer on this list.
iPad: use desktop density appropriately. A narrow LEFT drawer with user identity at TOP: simple human avatar and exact placeholder "你的昵称"; no X/close button, no Bot status below user identity. Below black "新建会话" pill; selected navigation "Bot"; "最近会话"; "设置" at bottom. Main area has same Bot list page, reasonable max width, search at top, list on left and a useful compact detail/preview pane on the RIGHT with selected Bot avatar/name "本机验证助手", "随时待命", rows "Soul", "记忆", "任务", button "开始聊天". Do not expand phone controls excessively. The right detail pane is clean and visually subordinate. Group rows accessible below Bots.
All Chinese text should be crisp and correct. Keep copy limited to specified text. Front-on flat digital screenshots, no thick device frames, no perspective, no decorative backgrounds, no watermark. Produce one landscape design board with generous neutral gutters and two large screen layouts.
