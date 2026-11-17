# Sotto for macOS: interface design spec

Build target: SwiftUI, macOS 14+. This file is the single source for the interface. Every number is in points (pt, 1pt = 1px of the reference at 100% scale). A value marked `(estimate)` was not found in the reference and is the best value available; everything else comes from the reference style files named in section 9.

## 1. Reference and limits

The layout, sizes, colours and conventions follow Telegram Desktop 7.x (the open source Qt client, GPLv3). Sotto is Apache-2.0, so only facts are taken: sizes, colour values and layout conventions, restated here in new words. Sections 10 to 18 come from Telegram Desktop 7.4.4 and lib_ui, with the sources listed in `thoughts/design-sources.md`.

Not taken, and never to be added: any code or style-file text, any icon or image asset, the wallpaper patterns, sounds, the logo, the name or the brand. Icons are SF Symbols (section 8). The chat background is a flat colour or a simple two-stop gradient made for Sotto. Avatars are coloured circles with initials. The look will be adjusted later; build every value from the tokens below so a later change is a token edit.

Product scope (do not design anything else): one-to-one chats with text, photos and files, all end-to-end encrypted; contacts added by a 64-hex-character id under a local name; an identity is a key pair made on the device (no phone, no username) with an optional display name and avatar sent to contacts encrypted; an outgoing message is waiting, stored by the relay, or not sent (no delivery or read receipts, no typing, no online status); the app is connected to a relay or reconnecting; a session with a contact can be reset. No groups, channels, stickers, calls, folders or stories.

## 2. Window and layout

| Item | Value |
|---|---|
| Minimum window size | 380 x 480 |
| Default window size | 800 x 600 (first launch, centered); the frame is restored afterwards |
| Chat list column, minimum width | 260 |
| Chat list column, maximum width | 540 |
| Chat list column, default width | 320 (estimate) |
| Chat area, minimum width | 380 |
| Two-column threshold | window width >= 640 (260 + 380) |
| Wide chat threshold | chat area width >= 880 |
| Divider between columns | 1pt line, token `divider` |

Resizing: the divider is draggable; the list width is clamped to 260...540 and also so the chat area keeps at least 380. The chosen width is saved (`@AppStorage`) and restored. When the window grows, the extra width goes to the chat area; the list keeps its width.

Single column (window narrower than 640): only one side is shown. With no chat open, the list fills the window; opening a chat replaces the list with the chat, and the chat header gets a back button (`chevron.left`) at its leading edge. Escape or the back button returns to the list.

Wide chat (chat area >= 880): the message column keeps the normal margins; bubbles never exceed the maximum width in 5.4, so the extra space stays empty background.

Implementation: a custom `HStack` with a drag handle is preferred over `NavigationSplitView`, which cannot reproduce the flat look and the exact column limits.

Title bar: `.windowStyle(.hiddenTitleBar)` with the content extended under the title area. A 28pt (estimate) strip runs across the full window top: background `titleBg`, the text "Sotto" centered, 13 regular, colour `titleFg` (active window) or `titleFgInactive`. The traffic lights sit in this strip at the system position. The strip is draggable. Below it start the list column and the chat area. No toolbar.

## 3. Colour tokens

Colours are sRGB hex; an 8-digit value is `#RRGGBBAA` (alpha last). Build them as a `Color` extension backed by an asset catalog or a two-value `NSColor(name:dynamicProvider:)`, so the theme switch in settings (system, light, dark) is a single `preferredColorScheme`.

| Token | Light | Dark | Used for |
|---|---|---|---|
| `windowBg` | #ffffff | #17212b | window, boxes, menus, list, top bars |
| `windowFg` | #000000 | #f5f5f5 | default text |
| `windowSubFg` | #999999 | #708499 | secondary text, captions |
| `windowBoldFg` | #222222 | #e9e8e8 | titles on plain background |
| `windowBgOver` | #f1f1f1 | #232e3c | generic hover background |
| `windowBgRipple` | #e5e5e5 | #24303d | pressed background |
| `titleBg` | #f1f1f1 | #242f3d | title strip |
| `titleFg` | #3e3c3e | #91a3b3 | title text, active window |
| `titleFgInactive` | #acacac | #6d7883 (estimate) | title text, inactive window |
| `divider` | #00000018 | #04080e56 | column divider, header and compose borders |
| `listBg` | #ffffff | #17212b | chat list background |
| `rowBgOver` | #f1f1f1 | #202b36 | chat row hover |
| `rowBgActive` | #419fd9 | #2b5278 | chat row of the open chat |
| `rowNameFg` | #222222 | #f5f5f5 | row name, normal |
| `rowTextFg` | #999999 | #7f91a4 | row preview, normal |
| `rowDateFg` | #999999 | #8696a8 | row time, normal |
| `rowFgActive` | #ffffff | #ffffff | name, preview, time and icons in the active row |
| `rowSentIconFg` | #5dc452 | #72bcfd | check mark in a row preview |
| `badgeBg` | #40a7e3 | #4082bc | unread badge |
| `badgeFg` | #ffffff | #ffffff | unread badge number |
| `badgeBgActive` | #ffffff | #ffffff | badge in the active row |
| `badgeFgActive` | #419fd9 | #2a5378 | badge number in the active row |
| `chatBgTop` | #dfe7d6 (estimate, Sotto's own) | #0e1621 (estimate) | chat area background, top stop |
| `chatBgBottom` | #cfdcc3 (estimate, Sotto's own) | #0e1621 (estimate) | chat area background, bottom stop |
| `msgInBg` | #ffffff | #182533 | incoming bubble |
| `msgOutBg` | #effdde | #2b5278 | outgoing bubble |
| `msgInFg` | #000000 | #f5f5f5 | incoming text |
| `msgOutFg` | #000000 | #e4ecf2 | outgoing text |
| `msgInDateFg` | #a0acb6 | #6d7f8f | incoming time |
| `msgOutDateFg` | #6db566 | #7da8d3 | outgoing time |
| `msgInLinkFg` | #168acd | #70baf5 | links in incoming text |
| `msgOutLinkFg` | #168acd | #83caff | links in outgoing text |
| `msgInShadow` | #748ea229 | #748ea200 | 2pt shadow under incoming bubble |
| `msgOutShadow` | #3ac3461d | #00000000 | 2pt shadow under outgoing bubble |
| `msgStoredIconFg` | #57b84c | #6bbfff | check mark: stored by the relay |
| `msgSendingIconFg` | #98d292 | #70a4d2 | clock: waiting in the outbox |
| `msgInSelectBg` | #c2dcf2 | #2e70a5 | text selection in incoming bubble |
| `msgOutSelectBg` | #b7dbdb | #2e70a5 | text selection in outgoing bubble |
| `serviceBg` | #517c417f | #213040d5 | date pill, empty state pill |
| `serviceFg` | #ffffff | #ffffff | date pill text |
| `unreadBarBg` | #fcfbfa | #182433 | unread separator band |
| `unreadBarFg` | #538bb4 | #ffffff | unread separator text |
| `unreadBarBorder` | #00000018 | #03080d00 | unread band top and bottom lines |
| `topBarBg` | #ffffff | #17212b | chat header, list top bar |
| `composeBg` | #ffffff | #17212b | compose bar |
| `composeIconFg` | #999999 | #6c7883 | compose and header icons |
| `composeIconFgOver` | #8a8a8a | #7c90a4 (estimate) | the same, hover |
| `placeholderFg` | #999999 | #6d7883 | placeholder, field not focused |
| `placeholderFgActive` | #aaaaaa | #4f5b67 | placeholder, field focused and empty |
| `searchBg` | #f1f1f1 | #242f3d | search field, idle |
| `searchBgActive` | #ffffff | #242f3d | search field, focused |
| `searchBorderActive` | #e5e5e5 | #242f3d | search field border, focused |
| `accent` | #40a7e3 | #5288c1 | filled buttons, send icon, radio, focus |
| `accentOver` | #39a5db | #2f6ea5 | filled button hover |
| `accentText` | #168acd | #6ab3f3 | text buttons, links outside bubbles, "Connecting..." |
| `lightButtonBgOver` | #e3f1fa (estimate) | #26394d (estimate) | text button hover |
| `danger` | #d14e4e | #ec3942 | destructive text and buttons |
| `dangerBgOver` | #fcdfde | #3b2228 (estimate) | destructive text button hover |
| `fieldError` | #d84d4d | #dc3d3d | validation message, error underline |
| `fieldGood` | #4ab44a | #5598db | positive validation message |
| `activeLine` | #37a1de | #6396cb | focused underline of a box field |
| `scrollBar` | #00000053 | #ffffff53 | scroll bar thumb |
| `scrollBarOver` | #0000007a | #ffffff7a | scroll bar thumb, hover |
| `toDownBg` | #ffffff | #1d2b3a | scroll-to-bottom circle |
| `toDownFg` | #999999 | #adb4ba | scroll-to-bottom arrow |
| `menuBg` | #ffffff | #17212b | context menu |
| `menuBgOver` | #f1f1f1 | #232e3c (see 9) | context menu item hover |
| `menuIconFg` | #999999 | #6c7883 | context menu and panel row icons |
| `boxBg` | #ffffff | #17212b | modal box |
| `boxTitleFg` | #404040 | #ebebeb | modal title |
| `layerBg` | #0000007f | #0000007f | dim behind a modal |
| `shadow` | #00000018 | #04080e56 | menu, box and button shadows |
| `toastBg` | #2c3033e5 | #000000b2 | toast |
| `toastFg` | #ffffff | #ffffff | toast text |
| `avatarFg` | #ffffff | #ffffff | avatar initials |

### Avatar colours

Seven colours are used (the reference has eight slots; the yellow one is unused). Each avatar is a circle filled with a vertical linear gradient from `top` to `bottom`. The same values serve both themes.

| Index | Name | Top | Bottom |
|---|---|---|---|
| 0 | red | #ff845e | #d45246 |
| 1 | green | #9ad164 | #46ba43 |
| 3 | blue | #5caffa | #408acf |
| 4 | purple | #b694f9 | #6c61df |
| 5 | pink | #ff8aac | #d95574 |
| 6 | sea | #5bcbe3 | #359ad4 |
| 7 | orange | #febb5b | #f68136 |

Rule: read the first 8 bytes of the contact's 32-byte id (the 64 hex characters decoded) as a big-endian `UInt64` `v`; `slot = v % 7`; index = `[0, 7, 4, 1, 6, 3, 5][slot]`. The same rule gives the user's own avatar from the user's own id. The colour never changes when the local name changes.

Initials: the first letter of the first two words of the local name, uppercased; a one-word name gives one letter; an empty name gives "?".

## 4. Typography

Family: the system font (SF Pro) via `Font.system(size:weight:)`; ids use `Font.system(size:weight:design: .monospaced)`. No custom font files. The reference base size is 13 (equal to the macOS body size). Line heights are the line box to reach with `.lineSpacing` or a fixed frame; all line heights are (estimate).

| Role | Size | Weight | Line height |
|---|---|---|---|
| Chat list name | 13 | semibold (estimate) | 18 |
| Chat list preview | 13 | regular | 18 |
| Chat list time | 13 | regular | 18 |
| Unread badge number | 12 | bold | badge height 19 |
| Chat header title | 14 (estimate) | semibold | 19 |
| Chat header subtitle | 13 | regular | 17 |
| Message text | 13 | regular | 18 |
| Message time | 13 | regular | 16 |
| Service text (date pill, empty state pill) | 13 | semibold | 17 |
| Unread separator text | 13 | semibold | 17 |
| Compose field text | 13 | regular | 18 |
| Placeholder | 13 | regular | 18 |
| Search field text and placeholder | 13 | regular | 18 |
| Modal title | 16 | semibold | 22 |
| Modal body | 14 | regular | 20 |
| Modal and box buttons | 14 | semibold | button height 34 |
| Context menu item | 13 | regular | 18 (row height 33) |
| Toast | 13 | regular | 18 |
| Connection bar text | 13 | regular | 17 |
| Empty state of the chat area | 13 | semibold | 17 |
| First launch title | 20 (estimate) | semibold | 26 |
| First launch body | 14 (estimate) | regular | 20 |
| Id display (my id, contact panel) | 14 (estimate) | regular, monospaced | 22 |
| Avatar initials: 46 / 40 / 80 avatar | 17 / 15 / 28 (estimate) | semibold | centered |

Truncation: list name and preview are one line with tail truncation; the preview shows the last message as plain text with line breaks replaced by spaces.

## 5. Components

### 5.1 Chat list row

| Item | Value |
|---|---|
| Row height | 62 |
| Paddings (left, top, right, bottom) | 10, 8, 10, 8 |
| Avatar | 46 circle at x 10, y 8 |
| Name | x 68, top 10, up to the time's leading edge minus 6 |
| Preview | x 68, top 34, up to the badge's leading edge minus 6 (or the right padding) |
| Time | right-aligned at right padding 10, same top as the name |
| Gap between name and time | 5 minimum |
| Status mark before the time (own last message) | 16 x 16 symbol box, 3 before the time |
| Badge | right-aligned at right padding 10 on the preview line; height 19, minimum width 19, horizontal padding 5, fully rounded |
| Minimum text width | 150 (below this the text is cut, never the avatar) |

States: normal (`listBg`, name `rowNameFg`, preview `rowTextFg`, time `rowDateFg`); hover (`rowBgOver`, colours unchanged); active, the open chat (`rowBgActive`, all text and icons `rowFgActive`, badge `badgeBgActive` with `badgeFgActive`); pressed (`windowBgRipple`). No separators between rows.

Time format: today "HH:mm" (per locale); within the week the short weekday ("Mon"); older the short date per locale.

### 5.2 List top bar and search field

| Item | Value |
|---|---|
| Bar height | 54 (estimate), background `topBarBg`, no bottom border |
| Leading menu button (Add contact, My id, Settings) | 40 x 40 hit area, 20pt symbol `composeIconFg`, left 7 |
| Search field | height 35, corner radius 18 (pill), outer padding 7 |
| Search text margins | left 12, top 8, right 30, bottom 5 |
| Search idle | fill `searchBg`, no border, placeholder "Search" in `placeholderFg` |
| Search focused | fill `searchBgActive`, 2pt border `searchBorderActive`, placeholder `placeholderFgActive` |
| Clear button | `xmark.circle.fill` 14pt `placeholderFg` in the 30pt right margin, shown when text is not empty |

Search filters the list by local name (case-insensitive substring) as the user types; no match shows "No contacts found", centered, 13 regular `windowSubFg`, 20 below the bar.

Connection bar: while the app is not connected to the relay, a 37pt bar appears under the search row, full column width, background `windowBgOver`: a small `ProgressView` at left 16, then "Connecting..." 13 regular `accentText`, 8 after the spinner. It slides in when the connection drops and out when connected. Nothing is shown while connected.

### 5.3 Chat header

| Item | Value |
|---|---|
| Height | 54, background `topBarBg`, 1pt bottom border `divider` |
| Back button (single column only) | 40 x 40, `chevron.left` 17pt, left 6 |
| Avatar | 42 circle, left 16 (after the back button when present), vertically centered |
| Title (local name) | 14 semibold `windowBoldFg`, x avatar + 12, top 9 (estimate) |
| Subtitle | 13 regular `windowSubFg`, top 30 (estimate): `lock.fill` 10pt, 4 gap, "end-to-end encrypted" |
| Right button (contact panel) | 40 x 40, `sidebar.right` 18pt `composeIconFg`, right 8 |

A click on the avatar or the title also opens the contact panel (7.4).

### 5.4 Message bubble

| Item | Value |
|---|---|
| Maximum bubble width | 430, and never more than the chat width minus 16 minus 56 |
| Content paddings (left, top, right, bottom) | 11, 8, 11, 8 |
| Outer margins, incoming / outgoing | left 16, right 56 / left 56, right 16 |
| Space above a message starting a group | 6 |
| Space below every message | 2 |
| Space above a message inside a group | 0 (so 2 inside a group, 8 between groups) |
| Large / small corner radius | 16 / 6 |
| Shadow | a 2pt solid band under the bubble, `msgInShadow` / `msgOutShadow`, no blur |
| Time placement | trailing bottom, right inset 9, bottom inset 8 from the bubble edge (the content padding, so the time shares the baseline of the last text line at size 13) |
| Space reserved before the time | 12 |
| Outgoing status mark | after the time, 24 reserved, symbol 12pt |

A group is consecutive messages of one sender with less than 5 minutes (estimate) between them and no date separator in between. Corners: on the sender's side (left for incoming, right for outgoing) a corner that touches another bubble of the group uses the small radius, the group's outer ends use the large radius; the opposite side always uses the large radius.

Tail: only on the last bubble of a group, at the bottom corner on the sender's side. That corner becomes square and a curved horn of 8 wide x 12 high (estimate) extends outward along the bottom edge, same fill, the shadow following its outline. Draw it as one `Shape` path with the bubble; an original curve, no image.

Time and text flow: if the last text line plus the time (and mark) fits in the maximum width, the time sits on that line; otherwise the bubble grows by one line and the time sits alone at the trailing bottom. Implement with a transparent spacer of the time's width appended to the text.

Text is selectable (`.textSelection(.enabled)`); links are detected, coloured `msgInLinkFg` / `msgOutLinkFg` and underlined on hover; selection uses `msgInSelectBg` / `msgOutSelectBg`. Hover shows nothing; a right click opens the context menu (5.9).

Photo and file bubbles are specified in 13.1 and 13.2; a bubble with only a photo has no content padding.

### 5.5 Date separator

A pill centered above the first message of each day: "Today", "Yesterday", or the date ("12 March", with the year when not the current year). Paddings left 12, top 3, right 12, bottom 4; margin top 10, bottom 2; fully rounded; background `serviceBg`, text 13 semibold `serviceFg`. While scrolling, the pill of the topmost visible day floats at top 8 and fades out 200ms after scrolling stops. It is drawn only while the topmost visible line is not that day's own pill in full view.

### 5.6 Unread separator

Inserted above the first unread incoming message when a chat is opened with unread messages: full-width band, height 32, margin 8 above and below, background `unreadBarBg`, 1pt top and bottom lines `unreadBarBorder`, centered "Unread messages" 13 semibold `unreadBarFg`. The chat opens scrolled so the band is near the top; it is removed when the chat is closed.

### 5.7 Scroll-to-bottom button

| Item | Value |
|---|---|
| Hit area | 52 x 62 |
| Circle | 44 (estimate), fill `toDownBg`, shadow `shadow` y 1, blur 4 (estimate) |
| Arrow | `chevron.down` 18pt (estimate), `toDownFg` |
| Position | right 12, bottom 10 above the compose bar |
| Shown when | scrolled more than 480 from the bottom |
| Unread badge | over the top of the circle, height 22, 12 bold, `badgeBg` / `badgeFg` |

A click scrolls to the newest message (animated under two screens of distance, otherwise a jump).

### 5.8 Compose bar

| Item | Value |
|---|---|
| Background | `composeBg`, 1pt top border `divider` |
| Height, one line | 46 |
| Field minimum / maximum height | 36 / 224, then it scrolls inside with a 6pt top fade |
| Attach button | at the leading edge, 14.1; the field starts after it |
| Field paddings | left 16 (estimate), top and bottom 5 |
| Placeholder | "Write a message..." `placeholderFg`, `placeholderFgActive` when focused |
| Send button | 44 x 46 at right 2, `paperplane.fill` 22pt (estimate) `accent` |
| Send button visibility | shown when the trimmed text is not empty, otherwise hidden |
| Gap between message list and bar | 8 |

The field grows one line at a time and the bar with it; the message list keeps its bottom anchored. Use an `NSTextView` representable to catch Enter. Each chat keeps its draft in memory; switching chats restores it.

### 5.9 Context menu

The system `.contextMenu` is acceptable for the first build; the custom look below is the target.

| Item | Value |
|---|---|
| Corner radius | 8 |
| Vertical padding of the menu | 8 top and bottom |
| Item paddings (left, top, right, bottom), rows without an icon | 17, 8, 17, 7 |
| Item paddings, rows with an icon | 54, 8, 17, 8, with a 24 box for the icon at x 15, y 5 (the 16pt symbol stays centered in the box) |
| Item icon | 16pt symbol `menuIconFg`, text 12 after it (estimate) |
| Item hover / destructive item | `menuBgOver` / text and icon `danger` |
| Shadow | `shadow`, blur 12, y 2 (estimate) |
| Minimum width | 200 (estimate) |

Message menu: for a photo, Save as... and Copy image; for a file, Save as... and Show in Finder; then Copy text; Delete for me (danger). Chat row menu: Contact info; Delete contact (danger).

### 5.10 Modal box

Every dialog (add contact, my id, rename, reset session, delete contact, settings) is this box, drawn over the window, never a sheet.

| Item | Value |
|---|---|
| Width | 320; 364 for wide boxes (add contact, my id, settings) |
| Corner radius | 8 |
| Background | `boxBg`, shadow `shadow` blur 24, y 4 (estimate) |
| Dim | `layerBg` over the whole window |
| Title | 16 semibold `boxTitleFg` at x 24, y 13; title area height 48 |
| Body paddings | left 24, top 14, right 24, bottom 8 |
| Button row | right-aligned; paddings left 6, top 10, right 10, bottom 10 |
| Button | height 34, text 14 semibold, horizontal padding 15, gap 8 (estimate), radius 6 |
| Normal button | no fill, text `accentText`, hover fill `lightButtonBgOver` |
| Destructive button | no fill, text `danger`, hover fill `dangerBgOver` |
| Field in a box | full body width, height 32, 1pt underline `divider`, 2pt `activeLine` when focused, `fieldError` on error |

Escape and a click on the dim close the box (not while an action runs). Return triggers the last (primary) button.

### 5.11 Toast

Bottom center of the window, 40 above the compose bar or the window bottom (estimate). Paddings 19, 13, 19, 12; margin 13; max width 480; radius 8; background `toastBg`, text 13 `toastFg`; held 1.5s (estimate). Used for "Id copied", "Session reset", "Contact deleted".

### 5.12 Empty state of the chat area and scroll bars

With no chat open, the chat background shows a centered pill "Select a chat to start messaging", 13 semibold `serviceFg` on `serviceBg`, paddings 12, 3, 12, 4, fully rounded. With no contacts, the pill reads "Add a contact to start messaging" and a text button "Add contact" (14 semibold `accentText`) sits 12 below it.

Scroll bars: system overlay bars (`.scrollIndicators(.automatic)`); the reference thumb is 4 wide in a 10 hit area, radius 2, minimum length 20, colours `scrollBar` / `scrollBarOver`.

## 6. Behaviour and motion

| Input | Action |
|---|---|
| Enter in the compose field | send (ignored when the trimmed text is empty) |
| Shift+Enter | new line |
| Escape in a chat | close the chat (empty state, or the list in single column) |
| Escape in the search field | clear the search, then leave the field |
| Cmd+F | focus the search field |
| Cmd+N | open "Add contact" |
| Cmd+, | open settings |
| Up / Down with search focused | move the selection; Enter opens the chat |
| Click on a row | open the chat, focus the compose field |

Hover fades in and out in 120ms. The active row changes instantly.

List order: rows sort by the time of the last message, newest first; a contact without messages sorts by its add time. A new message (incoming or sent) moves its row to the top. The reference moves rows without animation; Sotto animates the move with the default spring, and the badge number changes with `.contentTransition(.numericText())`.

| Element | Reference | SwiftUI |
|---|---|---|
| Hover in and out (rows, buttons, menu items) | 120ms | `.easeOut(duration: 0.12)` |
| Column width change, single/two column switch | 120ms | `.smooth(duration: 0.12)` |
| Modal box show and hide (dim fade, box scale 0.95 to 1 plus fade) | 200ms | `.smooth(duration: 0.2)` |
| Context menu show / hide | 200 / 150ms | `.smooth(duration: 0.2)` / `.easeIn(duration: 0.15)` |
| Toast fade in / slide up / fade out | 200 / 160 / 1000ms | `.easeOut(duration: 0.2)` / `.smooth(duration: 0.16)` / `.easeIn(duration: 1.0)` |
| Scroll-to-bottom button (fade plus 10 down) | 150ms | `.smooth(duration: 0.15)` |
| Floating date pill fade | 200ms | `.easeOut(duration: 0.2)` |
| Compose field growth, send button fade | 100ms | `.smooth(duration: 0.1)` |
| Connection bar in and out | 200ms (estimate) | `.smooth(duration: 0.2)` |
| Row reorder | none | `.spring(response: 0.3, dampingFraction: 1.0)` |
| New message at the bottom (fade plus 8 up) | none | `.smooth(duration: 0.2)` |
| Status mark clock to check | instant | `.contentTransition(.symbolEffect(.replace))` |

Motion rules: every movement is a spring without bounce (`.smooth`, or `dampingFraction: 1.0`); bounce belongs only to a gesture that ends with momentum, and the app has none. Animations start from the current on-screen value and can be interrupted: drive them with `withAnimation` on state, never with chained timers. No animation blocks input.

Reduced motion (`@Environment(\.accessibilityReduceMotion)`): every move and scale becomes a 150ms opacity cross-fade, colour and opacity changes stay, animated scrolls become jumps. Reduced transparency: `toastBg` becomes opaque in the same colour; `layerBg` stays as it is, because the dim behind a box is a dim, not a material, and an opaque one would hide the window it belongs to.

## 7. Screens of this product

### 7.1 First launch (no identity on the device)

The whole window, background `windowBg`, no list or chat. A centered column 300 wide (estimate):
- Circle 96 (estimate) filled `accent` with `lock.shield.fill` 44pt white.
- 24 below: "Welcome to Sotto", 20 semibold `windowBoldFg`, centered.
- 8 below, 14 regular `windowSubFg`, centered: "Your identity is a key pair made on this Mac. There is no phone number, no account and no profile."
- 28 below: filled button "Create identity", full column width, height 42 (estimate), radius 6, fill `accent` (hover `accentOver`), 14 semibold white. While the key is made, a small white `ProgressView` replaces the text.

After creation the column shows the title "Your id", the id block of 7.2, the line "Share this id with people who should be able to write to you." (14 regular `windowSubFg`), and two buttons: "Copy id" (text button) and "Continue" (filled), which opens the main layout.

### 7.2 My id (box, 364)

Title "My id". Body:
- Own avatar 80 centered, 16 below it the id: monospaced 14 `windowFg`, 16 groups of 4 characters separated by one space, 4 groups per line, 4 lines, centered, line height 22, selectable; background `windowBgOver`, radius 8, padding 12.
- 12 below: text button "Copy id" with `doc.on.doc` 14pt, `accentText`. Copying puts the 64 characters without spaces on the pasteboard and shows the toast "Id copied".

Button: "Close".

### 7.3 Add contact (box, 364)

Title "Add contact". Two fields, each with a label above it (13 regular `windowSubFg`, 6 above the field):
- "Name": placeholder "Local name", required, 64 characters max.
- "Id": placeholder "64 hex characters", monospaced 13; pasted spaces and line breaks are stripped and the text is lowercased.

Validation, 6 below the field in 13 regular `fieldError` with the underline in `fieldError`, checked on "Add" and live after the first failed attempt:

| Case | Message |
|---|---|
| Name empty | "Enter a name." |
| Id length not 64 after stripping | "The id must be 64 characters long." |
| Id has a character outside 0-9, a-f | "The id may contain only 0-9 and a-f." |
| Id is the user's own | "This is your own id." |
| Id already saved | "This contact is already saved as <name>." |

Buttons: "Cancel", "Add". On success the box closes and the new chat opens.

### 7.4 Contact panel

A right column inside the chat area, toggled by the header button: width 320 (estimate, range 292 to 392), 1pt leading border `divider`, background `windowBg`. When it would leave the chat under 380, it opens as a 364 box instead.
- Top bar 54: "Contact info" 14 semibold, `xmark` close button at right 8.
- Avatar 80 centered, 24 below the bar, showing the contact's photo (section 16) or the initials; 12 below: the local name, 16 semibold `windowBoldFg`; when the name the contact sent differs, 2 below the name the line "Name set by the contact: X", 13 regular `windowSubFg`; 4 below: `lock.fill` 10pt and "end-to-end encrypted", 13 regular `windowSubFg`.
- 24 below: section label "Id" (13 semibold `accentText`, left 24), the id block of 7.2 and a "Copy id" row.
- Action rows, height 44, icon 18pt `menuIconFg` at left 24, text 14 regular at left 60, hover `windowBgOver`:
  - `pencil` "Rename": a 320 box with the name field, buttons "Cancel", "Save".
  - `arrow.triangle.2.circlepath` "Reset session": box "Reset session?", body "A new encrypted session will be started with <name>. Messages already received stay.", buttons "Cancel", "Reset"; then the toast "Session reset".
  - `trash` "Delete contact" in `danger`: box "Delete <name>?", body "The contact and the whole chat history will be deleted from this Mac. This cannot be undone.", buttons "Cancel", "Delete" (destructive); then the chat closes and the toast "Contact deleted" shows.

### 7.5 Settings

The settings are the panel of section 11. "Relay" is in 11.7, "Theme" in 11.4 and "My id" in 12.4.

### 7.6 Connection, outbox, unknown senders, encryption

- Connection: shown only in the connection bar under the list search (5.2). The chat area does not change; a message sent while disconnected waits in the outbox.
- Outbox state, on every outgoing bubble after the time: `clock` 12pt `msgSendingIconFg` while waiting in the outbox; `checkmark` 12pt `msgStoredIconFg` once the relay stored it; `exclamationmark.circle.fill` 12pt `danger` when it is not sent (the relay refused it, or the contact's keys could not be had), with "Not sent." and the reason as the hover help and in the accessibility label. A text to a contact without a session waits with the clock from the moment it is sent, also across a restart, until a connection gives the session. A message that is not sent stays not sent; it can be deleted. Never a double check: there are no receipts. The same marks stand before the time in a list row whose last message is the user's own (check `rowSentIconFg`, clock `windowSubFg`, both `rowFgActive` in the active row).
- A message from a sender who is not in the contacts is not shown anywhere: no row, no badge, no notification.
- "End-to-end encrypted" is stated, not decorated: the header subtitle with a small lock (5.3), the contact panel under the name (7.4) and the first-launch text. No green titles, no locks in list rows, no special bubble colours, no "secret chat" banner: the normal chat look is the encrypted look.

## 8. SF Symbols

| Use | Symbol | Size |
|---|---|---|
| List menu button | `line.3.horizontal` | 20 |
| Search field leading icon (optional) | `magnifyingglass` | 13 |
| Clear search | `xmark.circle.fill` | 14 |
| Add contact (menu, empty state) | `person.badge.plus` | 16 |
| My id (menu) | `person.text.rectangle` | 16 |
| Settings (menu) | `gearshape` | 16 |
| Back (single column) | `chevron.left` | 17 |
| Contact panel toggle | `sidebar.right` | 18 |
| Close panel or box | `xmark` | 14 |
| Encrypted mark | `lock.fill` | 10 |
| First launch emblem | `lock.shield.fill` | 44 |
| Send | `paperplane.fill` | 22 |
| Waiting in the outbox | `clock` | 12 |
| Stored by the relay | `checkmark` | 12 |
| Not sent | `exclamationmark.circle.fill` | 12 |
| Scroll to bottom | `chevron.down` | 18 |
| Copy id, copy text | `doc.on.doc` | 14 / 16 |
| Rename | `pencil` | 18 |
| Reset session | `arrow.triangle.2.circlepath` | 18 |
| Delete contact, delete message | `trash` | 18 / 16 |
| Contact info (row menu) | `info.circle` | 16 |
| Attach button | `paperclip` | 22 |
| Attach menu: photo / file | `photo` / `doc` | 16 / 16 |
| Download (circle) | `arrow.down` | 22 |
| Cancel (circle) | `xmark` | 18 |
| Retry (circle) | `arrow.clockwise` | 20 |
| File (circle, done) | `doc.fill` | 22 |
| Avatar change overlay | `camera.fill` | 28 |
| QR code | `qrcode` | 18 |
| Save (viewer, QR box) | `square.and.arrow.down` | 20 / 14 |
| Viewer menu | `ellipsis` | 20 |
| Viewer arrows | `chevron.left`, `chevron.right` | 28 |
| Saved (toast) | `checkmark` | 18 |
| Rotate (crop) | `rotate.right` | 22 |
| Drop overlay | `arrow.down.doc` | 56 |
| Remove item (send box) | `xmark` | 14 |
| Settings tiles (white, in a 24 tile) | `person.crop.circle.fill` (profile), `bell.fill` (Notifications), `bubble.left.fill` (Chat settings), `arrow.up.arrow.down` (Data and storage), `lock.fill` (Privacy and security), `antenna.radiowaves.left.and.right` (Connection), `gearshape.2.fill` (Advanced) | 14 |
| Lock now | `lock.fill` | 16 |
| Open System Settings | `arrow.up.forward.app` | 14 |
| Folder row | `folder` | 16 |

Symbols use `.symbolRenderingMode(.monochrome)` in the colour token of their place.

## 9. Open points

Sources read: tdesktop `dialogs/dialogs.style`, `ui/chat/chat.style`, `window/window.style`, `chat_helpers/chat_helpers.style`, `info/info.style`, the night palette inside `Telegram/Resources/night.tdesktop-theme`; lib_ui `ui/colors.palette`, `ui/basic.style`, `ui/widgets/widgets.style`, `ui/layers/layers.style`.

Estimated, worth a look by the owner:
- Default list width 320, title strip 28, list top bar 54, chat header inner layout (title 14, offsets): not found as named values. The header height 54 comes from the info section's top bar.
- Fonts: list name weight, header title size, all line heights, avatar initials sizes.
- The chat background is Sotto's own: a light green gradient #dfe7d6 to #cfdcc3, picked to suit the reference `serviceBg`, which is tuned to a green wallpaper; dark #0e1621 flat. If the background changes, retune `serviceBg`.
- Dark values missing in the night palette: `titleFgInactive`, `composeIconFgOver`, `lightButtonBgOver`, `dangerBgOver`; the avatar gradient bottoms reuse the light values.
- `menuBgOver` in the night palette reads #ffffff, likely meant for another surface; #232e3c (dark `windowBgOver`) is used instead.
- Tail shape and size, the 5-minute grouping gap, toast hold time, the scroll-to-bottom circle, menu and box shadows, first-launch sizes.
- First launch, my id, contact panel and settings are Sotto's own, drawn in the same language; the reference has no equivalent screens.

Decisions for the owner:
- The send button hides when the field is empty (the reference shows a microphone there; Sotto has no voice).
- Row reorder is animated here, instant in the reference.
- Not built yet: the selection colours and the link underline on hover of 5.4. SwiftUI `Text` has no hook for either; both need the bubble text drawn by an AppKit text view, with the context menu of 5.9 kept.
- Context menus: system `.contextMenu` first, the custom look later.

### Added with sections 10 to 18 (2026-11-17)

Found in the reference (stated as numbers above): the settings row, toggle, radio, slider, divider-text and section-title sizes; the layer width (392, minimum 324, margins 48); the settings theme tile, background thumb, local storage and passcode sizes; the file bubble layout (44 circle, paddings, name and status tops, 268 minimum width, 3 ring); the photo size limits (430, 200 and 100); the media time pill (padding 8 and 2, offset 4, radius 6); the media viewer sizes and timings; the drag area card (20 inset, 27 and 19 fonts, 72 text block, 200ms); the crop handle size (10); the avatar button sizes (42 header photo, 100 and 80 cover photo); the page slide (240ms, 100 shift).

Not found, estimated here, worth a look by the owner:
- The whole of 14.1 as a menu: the reference attach button opens the file panel at once (a menu exists only for attachment bots). The two-item menu, its anchor offset and its shortcut are Sotto's.
- The profile cover layout of 11.2 mixes the reference photo and name offsets (22, 8, 112, 12, 37) with Sotto's own id line and QR button; the reference photo size there is not certain (80 from the offsets, 100 from another constant).
- Settings icon tiles: tile size 24, glyph 14 and the colour assignment per page; the tile colour tokens are the reference's, the assignment is not.
- All of 12.3 except the 10 handles and the fade colour: canvas size, minimum size, zoom range, output size and quality (the reference avatar crop is a separate editor with its own constants, partly not read).
- Photo bubble: the blur radius, the cross-fade, the loading arc speed, the caption top padding and the exact scale-up rule for a caption wider than the photo.
- The progress ring easing and fades, the byte formatter rules, the storage bar (the reference draws a pie), category colours, auto-lock options, passcode minimum length, the chat background presets and the `serviceBg` rule.
- Viewer: button top and right offsets, caption placement and width, the picture grow animation, the transparency checkerboard squares (colours are the reference's).
- Dark values missing in the night palette (kept as light, noted "same"): the settings tile colours, `viewerBg` family; `fileCircleOutOver` has no light value in the reference.

Decisions for the owner:
- Decided: largest file and the auto-download default: 100 MB, by the owner's approval of the plan on 2026-11-17; the stops of 11.5 end there; the reference default download limit is 10 MB.
- Decided: QR content is the plain 64 hex characters (as drawn here), by the owner's approval of the plan on 2026-11-17; a Sotto link such as `sotto://add?id=...` is not used; decoding a picture of a QR code into the Add contact field is not designed.
- Decided: the profile travels to contacts, by the owner's approval of the plan on 2026-11-17; the hint of 12.1 says so.
- "Clear cache" can lose files that the relay no longer holds (the blob lifetime); the box and the hint of 11.5 say so. A safer alternative is to clear only photos and files older than 30 days.
- Passcode: no recovery, and "Reset Sotto" needs the unlocked window, so a forgotten passcode means deleting the app data by hand; a recovery path would need a design.
- Decided: several photos selected go as separate messages, by the owner's approval of the plan on 2026-11-17 (no albums; the reference groups up to ten).
- Files sent as pictures: this spec sends a picture as a photo unless "Send as file" is checked; the reference's 72 square preview variant is not used.
- Notifications: "Hide contents while locked" in Privacy is this spec's reading of "previews hidden in notifications"; the Notifications page already has the general preview toggle.
- Dropping files on a chat row of another contact (the reference supports it) is not designed.
- Not built, as in section 9: selection colours and link underline of 5.4 stay an AppKit text view job; the caption of 13.1 and 13.2 needs the same view.

### Added with the settings panel (SOTTO-35, 2026-11-17)

Estimated in the build, worth a look by the owner:
- The panel top margin shrinks from 40 to 20 below a window height of 600.
- "Lock when the Mac sleeps" is on by default; a passcode also locks the window at every launch.
- Until the profile card, the cover of 11.2 has no name line: the avatar shows the initials of "Me", the short id sits next to it, and the QR button opens the My id box of 7.2.
- The passcode box when a passcode is on: a body line and the buttons "Cancel", "Turn off" (destructive), "Change"; "Change" asks for the current passcode above the two new fields; a wrong current passcode reads "Wrong passcode.".
- The auto-lock box has one button, "Close"; a radio applies at once. The value on the row is the radio title ("1 hour").
- The Connection value on the main page also reads "Not connected" (no identity yet) and "Can not connect" (stopped).
- The storage block shows the real size of the data folder as the total; Photos, Files and Other are 0 until photos and files are kept on the Mac, so "Clear cache" stays disabled.
- The macOS refusal state of 11.3 (disabled toggle, "Open System Settings") comes with the notifications card.

## 10. Additions to tokens and existing sections

### 10.1 New colour tokens

Colours are sRGB hex, `#RRGGBBAA` has alpha last, as in section 3. Where the reference night palette does not define a value, it keeps the light value (noted "same").

| Token | Light | Dark | Used for |
|---|---|---|---|
| `checkboxFg` | #b3b3b3 | #4f6276 | toggle track and ring when off, radio and check ring when off |
| `sliderBgInactive` | #e1eaef | #364554 | slider track, the part not filled |
| `sliderBgActive` | #40a7e3 | #4a81bc | slider track, the filled part and the handle |
| `settingsIconFg` | #ffffff | #ffffff | white glyph in a settings tile |
| `settingsIconBg1` | #f06964 | #f06964 (same) | tile red |
| `settingsIconBg2` | #6dc534 | #6dc534 (same) | tile green |
| `settingsIconBg3` | #ed9f20 | #ed9f20 (same) | tile light orange |
| `settingsIconBg4` | #56b3f5 | #56b3f5 (same) | tile light blue |
| `settingsIconBg5` | #7595ff | #7595ff (same) | tile dark blue |
| `settingsIconBg6` | #b580e2 | #b580e2 (same) | tile purple |
| `settingsIconBg8` | #f2925b | #f2925b (same) | tile dark orange |
| `fileCircleIn` | #40a7e3 | #3f96d0 | file circle, incoming |
| `fileCircleInOver` | #4eade3 | #489ed7 | the same, hover |
| `fileCircleOut` | #5fbe67 | #4c9ce2 | file circle, outgoing |
| `fileCircleOutOver` | #56b45e (estimate) | #54a4e9 | the same, hover |
| `fileGlyphIn` | #ffffff | #ffffff | glyph and progress ring on `fileCircleIn` |
| `fileGlyphOut` | #effdde | #ffffff | glyph and progress ring on `fileCircleOut` |
| `mediaOverlayBg` | #00000054 | #00000054 | time pill on a photo, loading circle on a photo |
| `mediaOverlayBgOver` | #00000074 | #00000074 | the same, hover; avatar change overlay |
| `mediaOverlayFg` | #ffffff | #fffffff2 | text and glyphs on `mediaOverlayBg` |
| `mediaOverlayGlyph` | #ffffff | #efefef | arrow, cross and progress ring on the loading circle of a photo |
| `fileTone1` | #72b1df | #3e7eba | file type tile in the send preview, blue |
| `fileTone2` | #5fbe67 | #3ea34a | the same, green |
| `fileTone3` | #e47272 | #d6454c | the same, red |
| `fileTone4` | #efc274 | #d99546 | the same, yellow |
| `viewerBg` | #222222eb | #222222eb | media viewer background (same in both themes) |
| `viewerControlBg` | #0000003c | #0000003c | viewer arrows hover circle |
| `viewerControlFg` | #ffffff | #ffffff | viewer icons and text |
| `viewerCaptionBg` | #11111180 | #11111180 | caption plate in the viewer |
| `viewerCaptionFg` | #ffffff | #ffffff | caption text |
| `viewerLinkFg` | #4db8ff | #70baf5 | links in a viewer caption |
| `viewerMenuBg` | #383838 | #383838 | viewer context menu |
| `viewerMenuBgOver` | #505050 | #505050 | viewer context menu item hover |
| `viewerMenuFg` | #ffffff | #ffffff | viewer context menu text |
| `imageBg` | #000000 | #000000 | behind an image smaller than its frame, crop and viewer canvases |
| `cropFadeBg` | #0000007f | #0000007f | fade outside the crop frame |
| `cropHandleFg` | #ffffff7f | #ffffff7f | crop frame corners and grid lines |
| `qrBg` | #ffffff | #ffffff (estimate) | QR code plate, white in both themes so scanners read it |
| `qrFg` | #000000 | #000000 (estimate) | QR code modules |

Reused as they are: `windowBg`, `windowBgOver` (also the gray band between settings groups), `windowBgRipple`, `windowSubFg`, `windowBoldFg`, `accent`, `accentText`, `danger`, `dangerBgOver`, `divider`, `boxBg`, `boxTitleFg`, `layerBg`, `shadow`, `toastBg`, `toastFg`, `serviceBg`, `serviceFg`, `msgInFg`, `msgOutFg`, `msgInDateFg`, `msgOutDateFg`, `msgStoredIconFg`, `msgSendingIconFg`, `menuBg`, `menuBgOver`, `menuIconFg`, `composeIconFg`, `composeIconFgOver`, `fieldError`, `activeLine`, `chatBgTop`, `chatBgBottom`.

### 10.2 Changes to sections 1 to 9

The changes were applied to sections 1, 5.3, 5.4, 5.8, 5.9, 7.4, 7.5 and 8 on 2026-11-17.

## 11. Settings

### 11.1 Panel, navigation and shared rows

Settings open from the list menu "Settings" or Cmd+,. They are a panel drawn over the window, like a box (5.10) but larger, with a stack of pages.

| Item | Value |
|---|---|
| Panel width | window width minus 96, at most 392, at least 324 |
| Window narrower than 420 | the panel fills the whole window: no dim, no radius, no side margins |
| Side margins | 48 each |
| Top margin | 40, shrinking to 20 when the window is short; bottom margin equal to the top (estimate) |
| Height | the height of the current page, at most the window height minus both margins; longer pages scroll inside |
| Corner radius, background, shadow, dim | 8, `boxBg`, `shadow` blur 24 y 4 (estimate), `layerBg` over the window |
| Top bar | height 56, background `boxBg`; the page scrolls under it; a 1 `divider` bottom line appears only while the page is scrolled (estimate) |
| Title | 16 semibold `boxTitleFg`, line 22, y 17; x 24 on the root page, x 60 on a sub page (estimate) |
| Close button (root page only) | `xmark` 14pt `composeIconFg`, hit area 48 x 56 at the right edge |
| Back button (sub pages) | `chevron.left` 17pt `composeIconFg`, hit area 60 x 56 at the left edge, hover `composeIconFgOver`, round hover fill 40 `windowBgOver` |
| Open and close of the panel | the box animation of section 6 (dim fade, scale 0.95 to 1 plus fade, 200ms) |

Closing: Escape, the close button, or a click on the dim close the panel from the root page; Escape and the back button pop one page on a sub page. Cmd+, while open does nothing. The panel always opens on the root page.

Page transition (push): the new page enters from the right edge over the full panel width while the page below moves left by 100 and is darkened by `slideFadeOutBg` (a 0.24 black, #0000003c, whose opacity follows the progress); a soft shadow band on the leading edge of the new page fades in with the progress. 240ms; the entering side eases out (fast start, calm stop). Pop is the same in reverse. While it runs, the panel height animates from the old page's height to the new one over the same 240ms. With reduced motion the pages cross-fade for 150ms and the height jumps.

Shared rows:

| Row | Layout |
|---|---|
| Button row | height 38 (padding top 10, bottom 8, line 20); left padding 22 without an icon and 60 with one; right padding 22; text 14 regular `windowBoldFg`; hover `windowBgOver` (120ms), pressed `windowBgRipple` |
| Tile icon | 24 x 24 rounded square, radius 6, fill one of `settingsIconBg1` to `settingsIconBg8`, white glyph `settingsIconFg` 14pt (estimate) centered; left 20, vertically centered; text starts at 60 |
| Value label | right aligned, right margin 23, 14 regular `accentText` |
| Toggle row | the toggle sits at the right with a right margin of 20; the text may take two lines of 20 when needed |
| Toggle | 34 x 20: track 28 x 14 with full radius, knob 16 diameter with a 2 border; off: track and border `checkboxFg`, knob `windowBg`; on: track and border `accent`, knob `windowBg`; the knob slides and the colours fade in 120ms |
| Section title | 14 semibold `accentText`, padding 22, 7, 10, 9 |
| Group gap | a band of `windowBgOver`, height 16 (estimate), between two groups of rows; the first group starts right under the top bar |
| Hint under a group | 13 regular `windowSubFg`, padding 22, 8, 22, 16, on a `windowBgOver` band that grows with the text; this is how every explanation in the pages below is shown |
| Radio row | padding 22, 5, 10, 5; radio 22 diameter, 2 ring `checkboxFg`, selected: ring and a centered dot (about 10, estimate) `accent`; label 14 regular `windowBoldFg` starting 15 after the radio; 5 between rows |
| Checkbox | the same box as the radio, 22, radius 4 (estimate), selected: filled `accent` with a white check |
| Slider | track 3 high, filled part `sliderBgActive`, rest `sliderBgInactive`, handle 15 diameter `sliderBgActive`; the row padding is 22, 8, 22, 8; the handle grows nothing on hover; the value changes at once, the handle follows without animation while dragged and snaps in 150ms |
| Field in a page | the box field of 5.10 (32 high, underline `divider`, `activeLine` focused, `fieldError` on error) with left and right margins 22 and the label above it as in 7.3 |
| Text buttons in a page | 14 semibold `accentText` (or `danger`), height 34, horizontal padding 15, hover fill `lightButtonBgOver` (or `dangerBgOver`), radius 6; a row of them is right aligned with padding 6, 10, 10, 10 |

### 11.2 Main page

Title "Settings". Layout from the top:

| Item | Value |
|---|---|
| Cover | height 104: avatar 80 at x 22, y 8 (the photo or the initials of 16); the name at x 112, y 12, 17 semibold `windowBoldFg`, line 24, one line, tail truncation; the id line at x 112, y 37 |
| Name when empty | "Add your name" in the same style but `accentText` |
| Id line | the first 8 and the last 8 characters of the id with "..." between, monospaced 13 `windowSubFg`; a QR button of 34 x 34 (`qrcode` 18pt `accentText`) sits at the right end of this line, 5 from the right edge (opens 12.4) |
| Cover click | a click on the avatar opens the picker of 12.2 directly; a click on the name or the empty part opens "Edit profile" (12); hover on the avatar shows the change overlay of 12.1 |
| Group 1 | tile rows (icon on the left, no value): "Notifications" (`settingsIconBg1`, red), "Chat settings" (`settingsIconBg4`), "Data and storage" (`settingsIconBg2`), "Privacy and security" (`settingsIconBg3`); the colours are an estimate |
| Group 2 | "Connection" (`settingsIconBg5`) with a value label: "Connected" (`accentText`) or "Connecting..." ; "Advanced" (`settingsIconBg6`) |
| Footer | under group 2, 13 regular `windowSubFg`, centered, padding 16: "Sotto" and the version number |

A row opens its page with the push of 11.1.

### 11.3 Notifications

| Order | Row |
|---|---|
| Title | "Notifications" |
| Section "macOS notifications" | toggle "Show notifications" (default on); toggle "Show sender name" (default on); toggle "Show message preview" (default on) |
| Hint | "Without a preview, a notification only says that a message arrived." |
| Section "Sound" | toggle "Play a sound" (default on) |
| Section "Dock" | toggle "Show unread count on the Dock icon" (default on) |
| Preview card | see below, at the end of the page |

If macOS refuses notifications, the first toggle is disabled (50% opacity) and a hint under the first section reads "Notifications are turned off for Sotto in System Settings." with a text button "Open System Settings" (14 semibold `accentText`, left 22).

Preview card (a sample of the notification, drawn in the page): margins 40, 20, 40, 58 around it as in the reference; the card is a rounded rectangle (radius 8, `windowBgOver`, estimate) with: avatar 36 at x 14, y 11; the title (sender, 14 semibold `windowBoldFg`) at x 64, y 9; the text (13 regular `windowSubFg`) at x 64, y 30; 9 below the text. It follows the three toggles live: sender name hidden shows "Sotto" as the title, preview hidden shows "New message".

Rules for the real notification: it never shows contents when the passcode lock is on and the lock is engaged (11.6). A message from an unknown sender never produces one (7.6).

### 11.4 Chat settings

| Order | Row |
|---|---|
| Title | "Chat settings" |
| Section "Theme" | three theme tiles: "System", "Light", "Dark" |
| Section "Text size" | a slider with the value label and a preview |
| Section "Chat background" | a grid of presets |
| Section "Sending" | two radio rows and a hint |
| Section "Time" | toggle "24-hour time" |

Theme tiles: each tile is 80 wide: a preview 80 x 92 (radius 6, estimate) showing a mini chat in that theme (background of the theme, one incoming bubble 40 x 14 at x 6, y 8 and one outgoing bubble 40 x 14 under it with 6 between them, bubble radius 2, aligned to the right with 6 from the edge), and below it, at y 99, the label 13 regular `windowSubFg` (selected: `accentText`) centered. "System" shows the preview split diagonally between light and dark. The selected tile has a 2 `accent` outline hugging the preview. The tiles are spread over the row (minimum gap 4) with row margins 16, 10, 16, 8. The choice applies at once (the single `preferredColorScheme` of section 3), the outline moves in 120ms.

Text size: the value label (14 regular `accentText`, "13 pt") is right aligned on the section title line. The slider runs from 12 to 20 pt in steps of 1 (estimate), default 13. It scales the message text, the message time, file names and statuses, captions and the compose field; the list, header and settings keep their size. Line height follows as size + 5 (estimate). Under the slider a preview of 120 high (estimate) with the chat background and two bubbles (5.4) reading "Hello" and "Hi", redrawn live.

Chat background: a grid of square tiles 76 x 76 (radius 8, estimate), horizontal gap 16, row gap 15 (estimate), grid padding 22 left and 10 right, 11 top, 12 bottom. At 392 wide this is four columns, three at 324. Tile 1 is "Default". The selected tile has a 2 `accent` ring with a 2 gap and a white check on `accent` (16 circle) at its bottom right. The presets are Sotto's own flat or two-stop gradients (no image, no pattern), all estimates:

| Name | Light top | Light bottom | Dark top | Dark bottom |
|---|---|---|---|---|
| Default | #dfe7d6 | #cfdcc3 | #0e1621 | #0e1621 |
| Mist | #e3ebf3 | #d3dfec | #0f1923 | #0b131c |
| Sand | #efe6d5 | #e2d5bc | #1a1712 | #14110d |
| Rose | #f1dfe3 | #e6cbd2 | #1f1519 | #170f12 |
| Slate | #dfe2e6 | #cdd2d9 | #151a20 | #0f1318 |
| Plain | #f4f4f4 | #f4f4f4 | #0e1621 | #0e1621 |

Choosing a preset sets `chatBgTop` and `chatBgBottom`. `serviceBg` must follow the preset: take the bottom colour, scale its brightness by 0.45 and use alpha 0.5 (estimate rule; the Default preset keeps the value of section 3).

Sending: radio "Enter sends the message" and radio "Cmd+Enter sends the message" (default the first). The hint under them changes with the choice: "Shift+Enter adds a new line." or "Enter adds a new line." This replaces the fixed rule of section 6.

Time: the toggle switches message times, the list time and the date pill between "14:05" and "2:05 PM". Default follows the system locale.

### 11.5 Data and storage

| Order | Row |
|---|---|
| Title | "Data and storage" |
| Section "Automatic download" | row "Photos" with the value "Up to 10 MB" and a slider under it; row "Files" with the same |
| Hint | "Larger photos and files wait for a tap. Small previews always load." |
| Section "Storage" | usage block, category rows, button "Clear cache" |
| Hint | "Files cleared from the cache can be downloaded again only while they are still stored on the relay." |
| Section "Download folder" | row "Save files to" with the folder name as value; toggle "Ask where to save each file" |

Automatic download: the row is the button row of 11.1 with a right value (14 regular `accentText`): "Off", "Up to 1 MB", "Up to 10 MB"... The slider below has the padding 22, 8, 22, 8 and stops Off, 1, 5, 10, 25, 50, 100 MB (estimate; 100 MB is the proposed largest file). Default 10 MB for both rows (the reference default download limit is 10 MB).

Storage block: a bar 4 high (radius 2) under a first line "Used by Sotto" with the total as value; the bar is split into the category colours `settingsIconBg4` (photos), `settingsIconBg2` (files), `settingsIconBg8` (other), margins 6, 6, 6, 6 around the bar, bar width the row width minus 44 (estimate; the reference bar is 174 in a pie layout). Category rows: height 44, padding 22, 0, 20, 0: a check circle 20 (the checkbox of 11.1, but 20, colour of its category when checked), 14 after it the category name (13 regular `windowBoldFg`, line 20), then the percent (13 semibold, 8 after the name) and the size at the right (13 regular `accentText`). Categories: "Photos", "Files", "Other" (messages and thumbnails are never cleared here). All three are checked at start.

Clear button: a filled button, margin 12, 6, 12, 9, height 38, radius 6, fill `accent` (hover `accentOver`), text 13 semibold white "Clear cache (245 MB)", disabled (`windowBgOver` fill, `windowSubFg` text) when nothing is checked. A click opens a 320 box: title "Clear cache?", body "Photos and files saved on this Mac will be removed from it. Messages stay. A file can be downloaded again only if the relay still has it." buttons "Cancel", "Clear" (destructive). Then the toast "Cache cleared". A cleared photo shows its small thumbnail and the download circle again (13.1); a file shows the not-downloaded state (13.2).

Download folder: the row opens the system folder panel; the value is the folder name (middle truncation), the full path is the hover help. Default: the user's Downloads folder.

### 11.6 Privacy and security

| Order | Row |
|---|---|
| Title | "Privacy and security" |
| Section "Local passcode" | row "Passcode" with the value "Off" or "On"; when on: row "Auto-lock" with the value, row "Lock Sotto now" with a `lock.fill` icon |
| Hint | "The passcode locks the app on this Mac. It is not sent anywhere and it cannot be recovered." |
| Section "Notifications" | toggle "Hide contents while locked" (default on; only enabled with a passcode) |
| Hint | "While Sotto is locked, notifications say only that a message arrived." |

Passcode box (320, 5.10): title "Set a passcode" (or "Change passcode" / "Turn off passcode" with three buttons when already on: "Change", "Turn off"); two fields stacked, "Passcode" and "Repeat passcode", each 256 wide and centered, masked text, the label above each as in 7.3, 23 between them (estimate: reference skip); under them the description 13 regular `windowSubFg` (min width 256, 7 above); the error line (13 regular `fieldError`) replaces the description when the fields differ ("The passcodes do not match.") or are shorter than 4 characters (estimate) ("Use at least 4 characters."). Buttons "Cancel", "Save". Turning off asks for the current passcode first.

Auto-lock: a 320 box with radio rows 200 wide (reference `autolockButton`): "1 minute", "5 minutes", "1 hour", "5 hours" (estimate; the reference options were not read), default "1 hour"; plus "Lock when the Mac sleeps" as a checkbox below (own).

Lock screen: over the whole window (list and chat hidden), background `windowBg`. Centered column 256 wide: the lock circle of 7.1 (96, `accent`, `lock.shield.fill` 44), 24 below "Sotto is locked" 20 semibold `windowBoldFg`, 16 below a masked field 256 wide (box field, autofocus, placeholder "Passcode"). Return unlocks. A wrong passcode shakes the field (4 left and right, 300ms) and shows "Wrong passcode." in `fieldError` under it. No hint, no reset link here; "Reset Sotto" lives only in 11.8 and needs the window unlocked. Escape does nothing. The app locks after the idle time of the auto-lock setting, on Cmd+L and, if checked, on sleep.

### 11.7 Connection

| Order | Row |
|---|---|
| Title | "Connection" |
| Section "Relay" | a field with the relay address (placeholder "wss://relay.example"); under it the state line; a button row "Cancel", "Save" |
| Section "Outbox" | row "Waiting to send" with the number of messages and files as value |

State line (13 regular, 6 under the field): a 8 diameter dot then the text, 8 apart. "Connected": dot `msgStoredIconFg`, text `windowSubFg`. "Connecting...": a 8 round progress arc (1 thick `windowSubFg`) and text `accentText`. "Can not connect": dot `danger`, text `danger`, with a text button "Try again" at the right. The address is checked as a URL on "Save" ("Enter a valid address." in `fieldError`); "Save" is enabled only after a change and applies by reconnecting; "Cancel" restores the saved address. Leaving the page with an unsaved change keeps the typed text until the panel closes.

The "Waiting to send" row is not a button; it is a status row (14 regular `windowBoldFg` with the value in `accentText`), "0" when empty.

### 11.8 Advanced

| Order | Row |
|---|---|
| Title | "Advanced" |
| Section "Data" | row "Data folder" with the folder name as value, row "Show in Finder" (button row) |
| Section "Reset" | row "Reset Sotto..." in `danger` (14 regular, hover `dangerBgOver`) |
| Hint | "Resetting deletes your identity, your contacts and all messages from this Mac." |

"Reset Sotto..." opens a 320 box: title "Reset Sotto?", body "Your identity, your contacts, all messages, photos and files will be deleted from this Mac. This cannot be undone. People you wrote to will see you as a new contact.", a field "Type RESET to confirm" (5.10 field), buttons "Cancel", "Reset" (destructive, enabled only when the field reads RESET, case-sensitive). After the reset the app shows the first launch of 7.1.

## 12. Profile

The profile is the display name and the avatar of the user's own identity; both are sent, encrypted, to every contact (the plan stage B). The id never changes.

### 12.1 Edit profile page

A sub page of Settings, title "Edit profile", back button. A right-aligned text button "Save" (14 semibold `accentText`, disabled `windowSubFg`) sits in the top bar at right 8, enabled only when the name or the photo changed.

| Item | Value |
|---|---|
| Avatar | 100 circle (the photo or the gradient and initials), centered, top 20 (estimate) |
| Initials size | 36 semibold (estimate), colour `avatarFg` |
| Change overlay | on hover and while the picker is open: `mediaOverlayBgOver` over the whole circle (fade 120ms) and `camera.fill` 28pt `mediaOverlayFg` centered |
| Drop | a picture dragged onto the avatar shows a 2 `accent` ring 3 outside the circle; dropping starts the crop step with that file |
| Set photo | text button "Set new photo" (14 semibold `accentText`), centered, 12 below the avatar; with a photo set it reads "Set new photo" and a second text button "Remove photo" (`danger`) sits 4 below |
| Name field | label "Display name" (13 `windowSubFg`) at left 22, 20 below the buttons; field left and right margin 22, placeholder "Your name"; 64 characters at most; a counter "12" (13 regular `windowSubFg`, right aligned on the label line) shows the characters left from 54 onward (estimate) |
| Hint | "Your name and photo are sent, encrypted, to your contacts. They can still rename you on their side." |
| Group gap, then section "Id" | the id block of 7.2 (monospaced 14, 4 lines of 4 groups, `windowBgOver`, radius 8, padding 12) with 22 side margins, then two action rows of 7.4 (height 44, icon 18 at left 24, text at left 60): `doc.on.doc` "Copy id" (toast "Id copied") and `qrcode` "Show QR code" (12.4) |

Leaving with unsaved changes (back, Escape, close): a 320 box "Discard changes?" with "Keep editing" and "Discard" (destructive). "Save" applies at once, shows the toast "Profile saved" and pops back to the main page; the profile is then sent to the contacts in the background, and the avatar overlay shows a progress ring (3 thick `mediaOverlayGlyph`, 8 inside the edge) only while the picture is being prepared, never for the delivery.

### 12.2 Avatar picker

The change overlay, "Set new photo" and the drop all do the same: open the system file panel (png, jpeg, heic; one file), then the crop box. A file that is not an image, or larger than 20 MB (estimate), shows the toast "Choose a picture." or "The picture is too large."

### 12.3 Crop box

A box of the width 364 (wide, 5.10) with the title "Choose the area" (16 semibold, area 48).

| Item | Value |
|---|---|
| Canvas | the full box width, height 340 (estimate), background `imageBg`; the picture is fitted inside with 20 margins (the reference gives the editor 20 around the canvas) |
| Crop shape | a circle (avatar), starting at the largest centered circle that fits in the picture and at most 280 across (estimate) |
| Fade | everything outside the shape is covered by `cropFadeBg` |
| Frame and handles | a 1 outline of `cropHandleFg` around the circle's bounding square, with four corner handles, squares of 10 (the reference point size) in `cropHandleFg`; drag a corner to resize (the shape stays a circle, the center follows the opposite corner), drag inside to move; the frame never leaves the picture |
| Minimum size | 100 across (estimate) |
| Grid | while dragging, thirds lines of 1 `cropHandleFg` over the crop area, fading in and out over 100ms |
| Zoom | scroll or pinch changes the scale of the picture under the frame, 1x to 4x (estimate); two-finger drag moves it |
| Rotate | below the canvas, a bar 48 high with one button 48 x 48, `rotate.right` 22pt `viewerControlFg` (on the dark canvas the button bar is drawn on `imageBg`), rotating the picture 90 clockwise; the frame resets |
| Buttons | "Cancel", "Apply" (primary) |

The result is a square of 512 x 512 (estimate) JPEG at quality 0.85 (estimate); a 128 x 128 version is kept for lists. After "Apply" the edit page shows the new avatar with a 200ms cross-fade; nothing is sent until "Save".

### 12.4 QR code box

A 364 box, title "QR code". Body: a plate 260 x 260 (the reference code size is 260) filled `qrBg`, radius 8 (estimate), centered, with the code inside a 16 quiet zone (the modules take 228); error correction level M (estimate). Under it, 16 below, the id block of 7.2. The code carries the 64-character id as plain text, so scanning it into the "Id" field of 7.3 or pasting it works the same (the exact form is an open point). Buttons: text buttons "Copy id" and "Save image" (`square.and.arrow.down` 14pt; saves the plate as a PNG with a 32 quiet zone through the save panel), and "Close".

## 13. Media in a chat

All colours are tokens; the bubble, the margins, the grouping, the corner and tail rules, the time and the status marks come from 5.4 and 7.6 and are not repeated.

### 13.1 Photo bubble

Frame size: the picture's own size is scaled down proportionally to fit in 430 x 430 (the reference maximum media size); it is never scaled up for the frame. Then the frame gets at least 200 wide when the message has a bubble (the reference bubble minimum) and at least 100 high; a picture narrower or flatter than that is shown cropped to the frame (aspect fill, centered). The frame width is also capped by the 5.4 maximum (the chat width minus 72).

| Case | Rule |
|---|---|
| Photo only | no content padding; the frame is the bubble; the image is clipped by the bubble shape (corner rule of 5.4, tail included) |
| Photo with caption | the photo is edge to edge at the top, its top corners follow the bubble, its bottom corners are square; the caption is under it with the content padding 11, 8, 11, 8 of 5.4 (the top padding 8 is an estimate); the time and status mark go to the end of the caption as in 5.4 |
| Caption wider than the photo | the bubble grows to the caption's width, up to the 5.4 maximum, and the photo is scaled up to that width, to at most its original pixel width, height following the ratio (estimate of the exact rule) |
| Text | the caption is message text (13 regular, `msgInFg` or `msgOutFg`), selectable, links as in 5.4 |

Time on a photo without caption: a pill over the image at its bottom right, 4 from the right and bottom edges; fill `mediaOverlayBg`, radius 6, text 13 regular `mediaOverlayFg`, horizontal padding 8 and vertical 2; for an outgoing photo the status mark (12pt, `mediaOverlayFg` in place of `msgStoredIconFg` and `msgSendingIconFg`) follows the time inside the pill; the failed mark stays `danger`.

Preview before the full picture: every photo message carries a small inline thumbnail and the picture size, so the frame has its final size from the first draw and the layout never jumps. Until the full picture is on this Mac the frame shows the thumbnail scaled up to the frame with a blur (radius about one tenth of the shorter side, estimate); when the full picture is ready it cross-fades over the thumbnail in 200ms (estimate). A frame without a thumbnail shows `imageBg` at 0.15 opacity (estimate) until the picture arrives.

States (a photo is shown in the frame; the circle is centered over it):

| State | Frame | Circle (44 diameter) | Click |
|---|---|---|---|
| Waiting to download (above the auto-download size, or off) | thumbnail, blurred | fill `mediaOverlayBg` (hover `mediaOverlayBgOver`, 200ms), glyph `arrow.down` 22pt `mediaOverlayGlyph`; under the circle, 8 below it, the size ("2.4 MB", 13 semibold `mediaOverlayFg`, on a pill like the time) | starts the download |
| Downloading | thumbnail, blurred | the same circle with a progress ring: 3 thick, inset 3 from the circle edge, `mediaOverlayGlyph`, starting at 12 o'clock and running clockwise; glyph `xmark` 18pt in the middle; before the first byte the ring is an indeterminate arc of about 6% to 35% turning (700ms a turn, estimate) | pauses the download (the partial data is kept); the circle goes back to the first state with the glyph `arrow.down` |
| Downloaded | the picture | none | opens the viewer (15) |
| Uploading (outgoing) | the local picture, sharp | circle and ring as when downloading, `xmark` cancels the upload | cancel removes the pending message |
| Waiting for the connection (outgoing) | the local picture | circle with `xmark` and no ring | cancel |
| Failed | thumbnail or picture | circle with `arrow.clockwise` 20pt `mediaOverlayGlyph`; the status mark of the time pill is `exclamationmark.circle.fill` in `danger`; hover help "Not sent. Click to retry." or "Could not download. Click to retry." | retries; an upload resumes from the last stored offset |
| Unavailable (the relay no longer has it) | thumbnail, blurred | none; a pill centered, 13 semibold `serviceFg` on `serviceBg`, paddings 12, 3, 12, 4: "No longer available" | none |

The ring appears and disappears with a 200ms fade (estimate); its value follows the progress with a short ease (about 200ms per step, estimate). When the last byte arrives the ring and circle fade out while the picture cross-fades in.

Hover on a downloaded photo shows nothing; the pointer is the arrow, the context menu has "Save as...", "Copy image", "Copy text" (if a caption), "Delete for me".

Several photos selected at once go as separate messages; albums (the reference groups up to ten with a 4 gap) are not designed (open point).

### 13.2 File bubble

Layout (reference: file without a thumbnail). The bubble width is the content width, at least 268 (the reference file minimum) and at most 430.

| Item | Value |
|---|---|
| Content paddings | left 12, top 8, right 10, bottom 8 (the file layout; replaces the 11, 8, 11, 8 of 5.4 for the file row) |
| Circle | 44 diameter at x 12, y 8 |
| Name | x 67 (12 + 44 + 11), top 12, 13 semibold `msgInFg` / `msgOutFg`, line 18, one line, middle truncation (keeps the extension visible) |
| Status line | x 67, top 34, 13 regular `msgInDateFg` / `msgOutDateFg` (the reference "media status" colours), line 18; its width stops 10 before the time |
| Row height | 60 (8 + 44 + 8) |
| Time and status mark | as in 5.4, at the trailing bottom, sharing the status line |
| Caption | under the file row, content padding of 5.4, the time moves to its end |

Circle colours: incoming `fileCircleIn` (hover `fileCircleInOver`), outgoing `fileCircleOut` (hover `fileCircleOutOver`); the glyph and the progress ring use `fileGlyphIn` / `fileGlyphOut`. Hover fades in 200ms. The ring: 3 thick, inset 3 from the circle, clockwise from 12 o'clock, drawn over the filled circle, as in 13.1.

States:

| State | Glyph (22pt) | Status text | Click on the circle or the row |
|---|---|---|---|
| Not downloaded | `arrow.down` | the size, "1.4 MB" | starts the download |
| Downloading | `xmark` with the ring at the progress | "0.4 / 1.4 MB" | pauses (partial data kept); the state goes back to "not downloaded" with the size |
| Downloaded | `doc.fill` | the size | opens the file with the system (Open); the context menu also has "Show in Finder" and "Save as..." |
| Uploading | `xmark` with the ring | "0.4 / 1.4 MB" | cancels and removes the pending message |
| Waiting for the connection | `xmark`, no ring | "Waiting for connection..." | cancels |
| Failed | `arrow.clockwise` | "Not sent. Click to retry." (outgoing) or "Could not download. Click to retry." (incoming), in `danger` | retries; the upload resumes from the last stored offset |
| Unavailable | `doc.fill` at 0.5 opacity | "No longer available" in `windowSubFg` | none |

Sizes are written with the system byte formatter (decimal units, like Finder), one decimal under 10 and none from 100 on (estimate); the text on the left of "/" and the one on the right share one unit.

The reference also has a file variant with a 72 square preview for files that are pictures; Sotto sends a picture as a photo (13.1) unless the user chooses "Send as file" (14.2), and then it uses the plain row above.

## 14. Attaching

### 14.1 Attach button and menu

The attach button sits at the leading edge of the compose bar: 44 x 46, `paperclip` 22pt, `composeIconFg` (hover `composeIconFgOver`), round hover fill 40 `windowBgOver` at x 2, y 3. The text field starts right after it, 0 gap (the first character 2 in, the placeholder margin), so the field's left padding of 5.8 now begins at 44 (estimate).

A click opens a popup menu anchored above the button, left edge on the button's left edge, 8 above it (estimate): background `menuBg`, radius 8, `shadow` blur 12 y 2, vertical padding 5, minimum width 200, rows with icons as in 5.9 (padding 54, 8, 17, 8, icon at 15, 5, text 13 regular):

| Item | Icon | Action |
|---|---|---|
| Photo | `photo` 16pt `menuIconFg` | the system file panel filtered to pictures (png, jpeg, heic, gif as a still), several allowed |
| File | `doc` 16pt | the system file panel with all types, several allowed |

Show 200ms, hide 150ms (popup menu timings). The menu closes on Escape, on a click elsewhere, and after a choice. Cmd+Shift+A opens it from the keyboard (own, estimate). A picture on the pasteboard pasted with Cmd+V into the field, or files dragged in (14.3), skip the menu and go straight to 14.2. The reference opens the file panel at once on a click; the two-item menu is Sotto's, because "photo or file" is a real choice here.

### 14.2 Send box (preview before sending)

A box of the wide width 364 (5.10). Title "Send photo", "Send file", "Send 3 photos" or "Send 3 files" (16 semibold).

| Item | Value |
|---|---|
| Body paddings | left 28, right 28, top 8 (estimate), bottom 18 |
| One picture | the preview at most 308 wide (the reference preview size) and 308 high (estimate), radius 6, centered |
| One file | a row: tile 44 x 44 (radius 4, fill `fileTone1` to `fileTone4` by a hash of the extension, the extension in white 13 semibold, 4 characters at most) at x 0; the name at x 55, top 6, 13 semibold `windowBoldFg`; the size at x 55, top 27, 13 regular `windowSubFg` (reference attach preview layout) |
| Several items | a column of the rows or previews, 10 apart; at most 5 are visible, the column scrolls; each row has a remove button (`xmark` 14pt `composeIconFg`, hit 34 x 34) at its right end |
| Send as file | a checkbox row "Send as file" (14 regular), 20 under the preview; shown for pictures only (a picture sent as a file keeps its original bytes and shows as a file bubble) |
| Caption | under it, 8 below the checkbox: a field of the 5.10 style, placeholder "Add a caption...", 13 regular, grows to at most 72 high (3 lines), 4096 characters at most (estimate); with several items the caption goes with the first one |
| Buttons | "Cancel", "Send" (primary, Return); with the send-by setting of 11.4 set to Cmd+Enter, Return inside the caption adds a line and Cmd+Return sends |
| Too large | an item above the largest size (proposed 100 MB) shows its size line as "Too large (largest is 100 MB)" in `fieldError`, is left out when sending, and "Send" is disabled when nothing is left; an empty file shows "The file is empty." |

Several items are sent as separate messages in the chosen order; there is no album.

### 14.3 Drag and drop overlay

When files are dragged over the chat area (not the list), an overlay card fades in over the whole chat area in 200ms and out in 200ms.

| Item | Value |
|---|---|
| Card | `boxBg`, radius 8, `shadow` (the box shadow); inset from the chat area by 10 at the top and bottom and 0 at the sides, plus an inner padding of 20, 10, 20, 10, so the visible card is 20 in from the sides and 20 from the top and bottom (reference margin and padding) |
| Content | centered as a group: the icon, 4 gap, the title, the subtitle; the text block is 72 high |
| Icon | `arrow.down.doc` 56pt (the reference icon is 64; estimate), colour as the text; hidden when the card is too short to hold it with the block (the card must be at least 72 + 2 x 28 + the icon high + 4) |
| Title | 27 semibold, "Drop files here" |
| Subtitle | 19 semibold, "to send them in the chat", at the bottom of the text block |
| Colours | `windowSubFg` normally; when the pointer is inside the card, `accentText`, fading in 200ms |
| No dim | the chat stays visible around the card; there is no `layerBg` |

When everything dragged is a picture, the card splits into two stacked zones with the same style: the top third "Drop files here / to send them as files" and the bottom two thirds "Drop photos here / to send them as photos" (the reference gives the media zone two thirds when photos are preferred); the zone under the pointer lights up. When nothing dragged is acceptable (a folder, a link) the card does not appear; a folder dropped shows the toast "Folders can not be sent." (estimate). A drop opens 14.2 with the items, with "Send as file" checked for the files zone.

## 15. Media viewer

An overlay that covers the whole window content (list, chat, title strip), opened by a click on a downloaded photo or on an avatar (16). The traffic lights stay on top of it at their place.

| Item | Value |
|---|---|
| Background | `viewerBg` over the window (the window shows through faintly, 92% opaque) |
| Open | the background fades in over 200ms and the picture grows from the frame of its bubble to its viewer size, 200ms, `.smooth` (estimate for the grow) |
| Close | Escape, a click on the empty background (not on the picture or a control), the close button; the reverse animation, 200ms |
| Picture | fitted to the window, never scaled above 100% on opening; centered; a picture with transparency sits on a light checkerboard (squares of 8, `#ffffff` and `#cccccc`) |
| Zoom | scroll or pinch; double click toggles fit and 100%; up to 8x; drag pans when it is larger than the window; Cmd+plus, Cmd+minus, Cmd+0 (fit) |
| Neighbours | Left and Right (or the arrows, or a horizontal two-finger swipe of 80) go to the previous and next picture of the chat (photos only, oldest to newest); the three nearest are preloaded; the first and last picture have no arrow |
| Not loaded yet | the thumbnail blurred in the final frame size, with the loading circle of 13.1 centered |

Controls (shown on mouse movement, hidden after 1100ms without movement over a 600ms fade; shown again over 200ms; hover fades 150ms):

| Control | Value |
|---|---|
| Name and date | bottom left, x 14; the name (the sender's local name, or "You") 13 semibold `viewerControlFg` with its top 47 above the window bottom; the date ("12 March, 14:05") 13 regular, top 26 above the bottom |
| Buttons | top right, right 8, top 8 (estimate), each 44 x 44 hit: `square.and.arrow.down` (Save as...), `ellipsis` (menu), `xmark` (close), icons 20pt `viewerControlFg` with a soft 1 shadow (`shadow`) for contrast, spaced 0 |
| Arrows | left and right zones 90 wide over the full height; inside, a glyph box of 46 x 54 centered vertically holding `chevron.left` / `chevron.right` 28pt `viewerControlFg`; the glyph shows with the controls and gets a 36 round `viewerControlBg` circle on hover |
| Caption | bottom center, 11 above the bottom controls (estimate): a plate with padding 11, 6, 11, 6, radius 6, fill `viewerCaptionBg`, text 13 regular `viewerCaptionFg`, links `viewerLinkFg`, at most as wide as the picture and 600 (estimate), up to 4 lines then it scrolls |

Context menu (right click on the picture, or the `ellipsis` button): the dark menu of 5.9 with `viewerMenuBg`, hover `viewerMenuBgOver`, text `viewerMenuFg`, destructive `danger`: "Save as...", "Copy image", "Show in chat", "Show in Finder", "Delete for me". Cmd+S saves, Cmd+C copies.

Save: the system save panel (default name the file name, or "Photo 2026-11-17 14.05.jpg"), then a toast at the top center, 24 from the top: fill `toastBg`, text 13 regular `toastFg`, "Saved to Downloads", paddings 55, 19, 29, 20 with a `checkmark` 18pt `toastFg` at x 23, y 21 (the reference save message); in at 200ms, visible until 2000ms, out by 2500ms.

An avatar opened from 16 uses the same viewer with a single picture: no arrows, name = the contact's local name, date = when the profile was updated; "Show in chat" is left out. A file is never opened here: a file opens with the system.

## 16. Avatars with a photo

An avatar is the circle of 3; a contact or the user may now have a photo. The rule is the same everywhere: if a photo is on this Mac, the circle is the photo scaled to fill it (aspect fill, centered, clipped by the circle, no border, no ring); otherwise the gradient with initials as before. The colour rule of 3 still gives the gradient; it never changes with the photo.

| Place | Size | Notes |
|---|---|---|
| Chat list row | 46 | at x 10, y 8 as in 5.1; also in the active row, no ring |
| Chat header | 42 (replaces 40) | in the 54 bar, left 16; a click opens the contact panel (not the viewer) |
| Contact panel | 80 | centered; a click opens the viewer on the photo (15); hover shows nothing |
| My id box, QR box, first launch | 80 | the user's own photo if set |
| Settings cover | 80 | 11.2; own overlay on hover |
| Edit profile | 100 | 12.1 |
| Notification preview and the real notification | 36 | 11.3 |
| Send box recipient | none | the box has no avatar |

Initials sizes stay as in section 4, and 36 for the 100 avatar (estimate).

Loading: the circle shows the gradient with initials until the photo is decoded, then cross-fades to the photo in 200ms (estimate). A new photo replaces the old one with the same fade. Decoded sizes (estimate): the 128 x 128 version for every avatar up to 64 and the 512 x 512 version for 80 and larger and the viewer.

The name rules stay: the local name always wins in the list and header; the display name a contact sent shows only in the contact panel (7.4). If a contact removes their photo, the circle goes back to initials.

## 17. SF Symbols added

The symbols of sections 11 to 16 are listed in the table of section 8, so a symbol is listed once.

## 18. Motion and timing added

| Element | Reference | SwiftUI |
|---|---|---|
| Settings page push and pop (slide, dim, shadow, panel height) | 240ms | `.timingCurve(0, 0.55, 0.45, 1, duration: 0.24)` |
| Toggle, radio, check, theme tile outline | 120ms | `.easeOut(duration: 0.12)` |
| Slider snap | 150ms | `.smooth(duration: 0.15)` |
| Crop grid fade | 100ms | `.easeOut(duration: 0.1)` |
| File and photo circle hover | 200ms | `.easeOut(duration: 0.2)` |
| Progress ring appear and fade | 200ms (estimate) | `.easeOut(duration: 0.2)` |
| Progress value step | 200ms (estimate) | `.easeOut(duration: 0.2)` |
| Thumbnail to full picture, avatar photo | 200ms (estimate) | `.smooth(duration: 0.2)` |
| Attach menu show / hide | 200 / 150ms | `.smooth(duration: 0.2)` / `.easeIn(duration: 0.15)` |
| Drag overlay fade, text colour | 200ms | `.smooth(duration: 0.2)` |
| Viewer open and close | 200ms | `.smooth(duration: 0.2)` |
| Viewer controls: show / hover / wait / hide | 200 / 150 / 1100 / 600ms | `.easeOut(duration: 0.2)` / `.easeOut(duration: 0.15)` / a 1.1s timer reset by each movement / `.easeIn(duration: 0.6)` |
| Viewer save toast | in 200, until 2000, out by 2500ms | `.easeOut(duration: 0.2)` then `.easeIn(duration: 0.5)` |
| Wrong passcode shake | 300ms, 4 left and right | a `GeometryEffect` or `keyframeAnimator`, 4 pt, three swings |

Motion rules of section 6 apply. With reduced motion: the page push and the viewer grow become 150ms cross-fades, the shake becomes a color flash of the error line, the progress ring still advances (it is progress, not decoration) but without eased steps.
