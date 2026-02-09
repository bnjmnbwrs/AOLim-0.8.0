# AOLim-0.8.0
Buddy list addon for FFXI

***What it does***

Buddy list

Manual /sea ping and “watch” polling (one at a time, throttled)

Online indicator: green online, gray offline, ? unknown, yellow while checking

Right-click buddy menu: Invite, Ping, Arm remove-confirm

Remove confirmation (3 seconds)

Optional UI tell input (off by default)

***What it does NOT do***

No packet interception

No chatbox injection /input /tell prefill

No automation beyond /sea watch tick

Why this is safe

Only uses visible game output (Search result: + tells)

Only sends normal commands players already use (/sea, /tell, /pcmd add)
