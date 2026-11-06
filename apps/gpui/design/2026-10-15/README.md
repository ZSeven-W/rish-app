# Rish interface direction — 2026-10-15

| Board | Image | Exact prompt | Status |
| --- | --- | --- | --- |
| Workspace sidebar and phone sheet | [Image](workspace-sidebar.png) | [Prompt](workspace-sidebar-prompt.txt) | Final responsive direction |
| Conversation workbench | [Image](conversation-workbench.png) | [Prompt](conversation-workbench-prompt.txt) | Conversation ownership reference; top tabs superseded |
| Phone main screens | [Image](phone-main.png) | [Prompt](phone-main-prompt.txt) | Visual exploration; global navigation superseded |
| Phone forms and settings | [Image](phone-forms.png) | [Prompt](phone-forms-prompt.txt) | Form visual reference |
| iPad landscape | [Image](ipad-landscape.png) | [Prompt](ipad-landscape-prompt.txt) | Responsive exploration; global navigation superseded |

Generated with the built-in imagegen tool. These are design references, not
screenshots or claims about implemented capabilities. Exact prompts are saved
beside each board. Existing native contracts, credentials, IME handling and
workflow behavior remain authoritative. Do not add fake timestamps, account
status, local-only privacy claims, line statistics or inert controls from a mockup.

## Final information architecture

`workspace-sidebar.png` supersedes the always-visible Chat/Files/Git strip and
large workspace pane in earlier boards. Global navigation is conversations and settings only.
Every conversation is bound to a workspace; the native host provisions and
remembers a default workspace. Existing history is migrated through the session
CAS contract without rewriting historical attempts or redirecting an existing
workspace identity. Workspace binding is not automatic model filesystem access.

Phones keep the chat mounted and open Files/Git in a high bottom sheet from the
header workspace button. When the main content width is at least 840 px, the
same tools occupy a 340–380 px right sidebar. Expanding the workspace uses the
full main pane and enables the directory/preview or changes/diff split.
The navigation sidebar continues to show conversations in every mode.

Implementation refinements from the user's annotated review: the conversation's
workspace selector now lives with the model and reasoning controls in the
composer, using one compact row on phones with model/thinking next to Send.
The header uses Lucide PanelRight for the
workspace toggle. The left rail uses compact conversation rows; the right file
inspector shows the current directory above the selected preview when height
permits, with a single-document fallback in short windows. It is a real current
directory listing, not a simulated recursive file tree.

## Shared visual language

- Codex-like restraint, existing Lucide icons, warm neutral canvas, white cards,
  charcoal primary actions and semantic green only for actual positive states.
- 20 px phone gutters; 24 px roomy gutters. Body 14–15 px, secondary 12–13 px,
  section 16–18 px, hero 26–30 px. Text/control sizes do not scale with screens.
- Main cards 18 px radius, small controls 12 px, sheets 28 px. Thin borders,
  very subtle elevation only on floating surfaces. Avoid walls of pill buttons.
- Touch controls remain at least 44 pt on iOS and 48 dp on Android. Preserve
  focus, accessibility IDs, disabled-state guards and all debug selectors.
- Light palette: canvas F8F8F6, white panels, surface F0F1EE, raised E8EAE5,
  line E1E4DE, text 242722, muted 71766D, accent 272B25.
- Dark palette: canvas 151715, panels 20231F, surface 1B1E1A, raised 2B3029,
  line 373E34, text EDF0E9, muted A4AE9D, accent E9EEE3.

## Responsive behavior

- iPhone and narrow iPad windows: single column + drawer; retain full actions.
- Regular windows: persistent navigation; chat reading column stays <=720 px.
- Main content width >=760 px: files use a 260 px directory/list pane and a
  flexible document preview; Git uses a 320 px changes/action pane and a flexible
  diff pane. These can coexist with the global sidebar. Do not duplicate IDs.
- Settings width >=760 px: accounts and preferences become separate columns.
- Use current window content width after sidebars/insets, never device names or
  assumed orientation. Collapse cleanly during Split View and resizing without
  dropping selected files, drafts, scroll handles or pending requests.
- iPad forms/editors are width constrained; native keyboard avoidance and small
  landscape layouts must retain their established minimum usable viewports.

The tablet should expose more simultaneous working context, like a desktop,
while maintaining the same typography and control dimensions as the phone.
