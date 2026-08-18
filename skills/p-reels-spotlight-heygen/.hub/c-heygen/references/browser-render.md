# HeyGen — Browser UI Render (Chrome Automation)

Use when MCP is unavailable or premium_credits are needed.

## Critical Order

**Always set avatar/look/motion/background FIRST — script LAST.**

HeyGen's Script Writer AI rewrites any text you type directly into the script field. Bypass this by pasting via `ClipboardEvent('paste')` dispatch.

## Step-by-Step Chrome Automation

### 1. Navigate to HeyGen Studio

```
URL: https://app.heygen.com/studio
```

### 2. Create New Video

Click "Create" → "New Video" → select "Blank Video".

### 3. Set Avatar

1. Click "Avatar" in left panel
2. Search for avatar by name (e.g., "Marcus CFW")
3. Select avatar — wait for preview to load
4. Select Look (outfit/style variant)
5. Select Motion (natural / expressive)

### 4. Set Background

1. Click "Background"
2. Select "Color" tab
3. Enter hex `#00FF00` exactly — **NEVER use the eyedropper or sample from video**
4. Confirm color preview shows pure green

### 5. Set Voice

1. Go back to "Voice" settings
2. Select or confirm voice ID matches the production

### 6. Paste Script (CRITICAL STEP)

**Do NOT type directly into the script field** — HeyGen's AI will rewrite it.

Use browser console to paste via clipboard event:

```javascript
// In Chrome DevTools Console:
const textarea = document.querySelector('[data-testid="script-input"]');
// Or: const textarea = document.querySelector('.script-editor textarea');
textarea.focus();

const text = `YOUR SCRIPT TEXT HERE`;
const dataTransfer = new DataTransfer();
dataTransfer.setData('text/plain', text);
const event = new ClipboardEvent('paste', { clipboardData: dataTransfer, bubbles: true });
textarea.dispatchEvent(event);
```

If selector doesn't work, try: `document.querySelector('div[contenteditable="true"]')`

### 7. Set Video Dimensions

Click settings (gear icon) → Resolution → 1280×720 (HD).

### 8. Submit Render

Click "Generate Video" or "Submit". Note the video ID from the URL:
`https://app.heygen.com/video/{VIDEO_ID}`

## Polling After Submit

Use Floe API (see main SKILL.md) to poll render status. Do NOT refresh the HeyGen browser tab — it doesn't help.

## Common Gotchas

| Issue | Fix |
|-------|-----|
| Script got AI-rewritten | Always use ClipboardEvent paste, never type |
| Wrong green color | Always type `#00FF00` manually, never sample |
| Credits charged to wrong pool | OAuth MCP = premium_credits; API key = api_credits |
| Video stuck "processing" | Wait 15 min, then poll Floe API for status |
| Avatar preview not loading | Hard refresh, clear cache, try again |
| Background shows as white | Color wasn't saved — click "Apply" after entering hex |

## Credit Pool Reference

| Access Method | Credit Pool |
|--------------|-------------|
| Browser UI | Premium credits |
| OAuth MCP (`mcp__heygen__*`) | Premium credits |
| Stdio MCP + API key | API credits |
| REST API | API credits |

**Check credits before submitting:** API credits and premium credits are separate pools.
