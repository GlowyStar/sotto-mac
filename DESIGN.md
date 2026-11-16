# Sotto for macOS: interface design spec

Build target: SwiftUI, macOS 14+. This file is the single source for the interface. Every number is in points (pt, 1pt = 1px of the reference at 100% scale). A value marked `(estimate)` was not found in the reference and is our best value; everything else comes from the reference style files named in section 9.

## 1. Reference and limits

The layout, sizes, colours and conventions follow Telegram Desktop 7.x (the open source Qt client, GPLv3). Sotto is Apache-2.0, so only facts are taken: sizes, colour values and layout conventions, restated here in our own words.

Not taken, and never to be added: any code or style-file text, any icon or image asset, the wallpaper patterns, sounds, the logo, the name or the brand. Icons are SF Symbols (section 8). The chat background is a flat colour or a simple two-stop gradient of our own. Avatars are coloured circles with initials. The look will be adjusted later; build every value from the tokens below so a later change is a token edit.

Product scope (do not design anything else): one-to-one text chats, all end-to-end encrypted; contacts added by a 64-hex-character id under a local name; an identity is a key pair made on the device (no phone, no photo, no username); a message is either waiting in the outbox or stored by the relay (no delivery or read receipts, no typing, no online status); the app is connected to a relay or reconnecting; a session with a contact can be reset. No groups, channels, media, stickers, calls, folders or stories.

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
| `chatBgTop` | #dfe7d6 (estimate, ours) | #0e1621 (estimate) | chat area background, top stop |
| `chatBgBottom` | #cfdcc3 (estimate, ours) | #0e1621 (estimate) | chat area background, bottom stop |
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
| Avatar | 40 (estimate) circle, left 16 (after the back button when present), vertically centered |
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
| Time placement | trailing bottom, right inset 9, bottom inset 3 from the bubble edge |
| Space reserved before the time | 12 |
| Outgoing status mark | after the time, 24 reserved, symbol 12pt |

A group is consecutive messages of one sender with less than 5 minutes (estimate) between them and no date separator in between. Corners: on the sender's side (left for incoming, right for outgoing) a corner that touches another bubble of the group uses the small radius, the group's outer ends use the large radius; the opposite side always uses the large radius.

Tail: only on the last bubble of a group, at the bottom corner on the sender's side. That corner becomes square and a curved horn of 8 wide x 12 high (estimate) extends outward along the bottom edge, same fill, the shadow following its outline. Draw it as one `Shape` path with the bubble; our own curve, no image.

Time and text flow: if the last text line plus the time (and mark) fits in the maximum width, the time sits on that line; otherwise the bubble grows by one line and the time sits alone at the trailing bottom. Implement with a transparent spacer of the time's width appended to the text.

Text is selectable (`.textSelection(.enabled)`); links are detected, coloured `msgInLinkFg` / `msgOutLinkFg` and underlined on hover; selection uses `msgInSelectBg` / `msgOutSelectBg`. Hover shows nothing; a right click opens the context menu (5.9).

### 5.5 Date separator

A pill centered above the first message of each day: "Today", "Yesterday", or the date ("12 March", with the year when not the current year). Paddings left 12, top 3, right 12, bottom 4; margin top 10, bottom 2; fully rounded; background `serviceBg`, text 13 semibold `serviceFg`. While scrolling, the pill of the topmost visible day floats at top 8 and fades out 200ms after scrolling stops (optional, see 9).

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
| Item paddings (left, top, right, bottom) | 17, 8, 17, 7 |
| Item icon | 16pt symbol `menuIconFg`, text 12 after it (estimate) |
| Item hover / destructive item | `menuBgOver` / text and icon `danger` |
| Shadow | `shadow`, blur 12, y 2 (estimate) |
| Minimum width | 200 (estimate) |

Message menu: Copy text; Delete for me (danger). Chat row menu: Contact info; Delete contact (danger).

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

List order: rows sort by the time of the last message, newest first; a contact without messages sorts by its add time. A new message (incoming or sent) moves its row to the top. The reference moves rows without animation; we animate the move with the default spring, and the badge number changes with `.contentTransition(.numericText())`.

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

Reduced motion (`@Environment(\.accessibilityReduceMotion)`): every move and scale becomes a 150ms opacity cross-fade, colour and opacity changes stay, animated scrolls become jumps. Reduced transparency: `layerBg` and `toastBg` become opaque in the same colour.

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
- Avatar 80 centered, 24 below the bar; 12 below: the local name, 16 semibold `windowBoldFg`; 4 below: `lock.fill` 10pt and "end-to-end encrypted", 13 regular `windowSubFg`.
- 24 below: section label "Id" (13 semibold `accentText`, left 24), the id block of 7.2 and a "Copy id" row.
- Action rows, height 44, icon 18pt `menuIconFg` at left 24, text 14 regular at left 60, hover `windowBgOver`:
  - `pencil` "Rename": a 320 box with the name field, buttons "Cancel", "Save".
  - `arrow.triangle.2.circlepath` "Reset session": box "Reset session?", body "A new encrypted session will be started with <name>. Messages already received stay.", buttons "Cancel", "Reset"; then the toast "Session reset".
  - `trash` "Delete contact" in `danger`: box "Delete <name>?", body "The contact and the whole chat history will be deleted from this Mac. This cannot be undone.", buttons "Cancel", "Delete" (destructive); then the chat closes and the toast "Contact deleted" shows.

### 7.5 Settings (box, 364)

Title "Settings". Sections separated by 1pt `divider` lines with 12 above and below, each with a label in 13 semibold `accentText`:
- "Relay": a field with the relay address (placeholder "wss://relay.example"), checked as a URL on "Save" with the message "Enter a valid address."; under it the state, 13 regular: "Connected" in `windowSubFg` or "Connecting..." in `accentText`.
- "Theme": three rows of height 40, a radio circle 18 (ring `windowSubFg`; selected: filled `accent` with a white dot 8) and "System", "Light", "Dark" in 14 regular. The change applies at once.
- "Identity": a row "My id" that opens 7.2.

Buttons: "Cancel", "Save" (enabled only when the relay field changed).

### 7.6 Connection, outbox, unknown senders, encryption

- Connection: shown only in the connection bar under the list search (5.2). The chat area does not change; a message sent while disconnected waits in the outbox.
- Outbox state, on every outgoing bubble after the time: `clock` 12pt `msgSendingIconFg` while waiting in the outbox; `checkmark` 12pt `msgStoredIconFg` once the relay stored it. Never a double check: there are no receipts. The same marks stand before the time in a list row whose last message is our own (check `rowSentIconFg`, clock `windowSubFg`, both `rowFgActive` in the active row).
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
| Scroll to bottom | `chevron.down` | 18 |
| Copy id, copy text | `doc.on.doc` | 14 / 16 |
| Rename | `pencil` | 18 |
| Reset session | `arrow.triangle.2.circlepath` | 18 |
| Delete contact, delete message | `trash` | 18 / 16 |
| Contact info (row menu) | `info.circle` | 16 |

Symbols use `.symbolRenderingMode(.monochrome)` in the colour token of their place.

## 9. Open points

Sources read: tdesktop `dialogs/dialogs.style`, `ui/chat/chat.style`, `window/window.style`, `chat_helpers/chat_helpers.style`, `info/info.style`, the night palette inside `Telegram/Resources/night.tdesktop-theme`; lib_ui `ui/colors.palette`, `ui/basic.style`, `ui/widgets/widgets.style`, `ui/layers/layers.style`.

Estimated, worth a look by the owner:
- Default list width 320, title strip 28, list top bar 54, chat header inner layout (avatar 40, title 14, offsets): not found as named values. The header height 54 comes from the info section's top bar.
- Fonts: list name weight, header title size, all line heights, avatar initials sizes.
- The chat background is ours: a light green gradient #dfe7d6 to #cfdcc3, picked to suit the reference `serviceBg`, which is tuned to a green wallpaper; dark #0e1621 flat. If the background changes, retune `serviceBg`.
- Dark values missing in the night palette: `titleFgInactive`, `composeIconFgOver`, `lightButtonBgOver`, `dangerBgOver`; the avatar gradient bottoms reuse the light values.
- `menuBgOver` in the night palette reads #ffffff, likely meant for another surface; #232e3c (dark `windowBgOver`) is used instead.
- Tail shape and size, the 5-minute grouping gap, toast hold time, the scroll-to-bottom circle, menu and box shadows, first-launch sizes.
- First launch, my id, contact panel and settings are ours, drawn in the same language; the reference has no equivalent screens.

Decisions for the owner:
- The send button hides when the field is empty (the reference shows a microphone there; Sotto has no voice).
- The floating date pill (5.5) adds work and can be left out of the first build.
- Row reorder is animated here, instant in the reference.
- Context menus: system `.contextMenu` first, the custom look later.
