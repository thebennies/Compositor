# The assistant

View › Show Assistant (⇧⌘A) opens a chat beside the Layers panel. Ask for a change in plain language and a model,
reached through [OpenRouter](https://openrouter.ai), carries it out by calling tools that drive the app's own editing
code. Each change shows on the canvas as it happens and is one step in Edit › Undo, named as the menu names it
("Image Size", "Highlight Lines"), so ⌘Z takes it back like any other edit.

Some things to try:

- "Resize my image to 1920 wide, then export as PNG."
- With a scan, screenshot or photo of a page open: "Highlight the lines about payment terms in pink, and the lines
  with dates in yellow."
- Point instead of describing: select some lines with the Marquee or Lasso, then say "make these pink". Only text lines
  whose centers are inside the selection are highlighted.
- "Undo that."

Return sends; ⇧Return starts a new line. While the model works, Send turns into Stop (⌘.), which cancels the request in
flight and any tool calls still to come. A request runs for at most 25 model calls. The trash button clears the
conversation. The chat belongs to its project tab for as long as the app is open and is never saved in the `.comp`
file.

## Setting it up

1. Make a key at [openrouter.ai/keys](https://openrouter.ai/keys).
2. Open Compositor › Settings… (⌘,), paste it under OpenRouter and click Save Key. It's kept in your login keychain, as a
   generic password under the service `<bundle id>.openrouter`, never in preferences or a project.
3. Optionally change the model. The default is `deepseek/deepseek-chat`; any OpenRouter model that supports tool calls
   works. The model id is kept in the app's preferences (`assistant.model`).

## Privacy

The assistant never sends the image. What leaves the Mac, to OpenRouter and the model's provider, is your messages, the
document's size, resolution, name, layer list and selection bounds, and the text that `recognize_text` finds, with each
line's box. Text recognition runs on the Mac with Apple's Vision framework, so even a text-only model like DeepSeek can
work with a page it never sees.

## Tools

| Tool | What it does | Undo step |
| --- | --- | --- |
| `get_document_info` | The canvas's width, height and resolution; `sourceName`; the layers bottom to top (id, name, visibility, opacity, blend mode, kind); the active layer's id; the selection's bounds in document pixels, or null. | — |
| `resize_image` | Image Size without its sheet. `width`, `height`, `long_edge`, `keep_aspect` (default true), `resolution`. One side keeps the aspect ratio; `long_edge` scales the longer side. | Image Size |
| `export_png` | The flattened canvas as a PNG, through a save panel named after the document. Reports where it was saved, or that it was cancelled. | — |
| `recognize_text` | Vision's accurate text recognition over the flattened canvas (on white). Returns lines `{ id, text, box }`, boxes in document pixels with a top-left origin. `within_selection` keeps only lines whose centers are in the selection. | — |
| `highlight_lines` | Rounded highlighter marks over lines from the last `recognize_text`, by id: padded by 15% of the line's height and 4 px either side, filled with the color on a pixel layer per color ("Highlight Pink"), made at the top of the stack with Multiply if it isn't there, so the text stays crisp. `color` is a name (pink `#FF7AC6`, yellow `#FFE24D`, green, blue, orange, purple, red, cyan, gray) or a hex string; `layer_name` picks another layer. | Highlight Lines |
| `undo` | Edit › Undo. | — |

Tools that edit wait for the editor: while a dialog or sheet is open, a transform, crop, text edit or stroke is in
progress, or another operation is running, they return an error the model passes on, rather than editing underneath
it. A tool given bad arguments (malformed JSON, a word where a number goes, an unknown line id) answers with the
problem, and the model usually corrects itself and calls again.

## Adding a tool

Everything lives in `Compositor/Assistant/`:

- `OpenRouterClient.swift`: the request and response types and the HTTP call.
- `AssistantKeychain.swift`: the API key.
- `AssistantTools.swift`: the tools' descriptions and JSON Schemas, argument reading, and `AssistantToolRunner`, which
  carries them out on the project's `EditorSession`.
- `AssistantSession.swift`: the chat, the system prompt, and the loop that sends the conversation and runs the calls.
- `TextLines.swift`, `HighlightLayer.swift`: recognition, the coordinate conversion, and the marks.
- `AssistantPanel.swift`: the panel and the Settings view.

To add one:

1. Add a case to `AssistantTool`, with its name as the raw value (snake case), a `summary` for the model, and its
   `parameters` schema.
2. Handle it in `AssistantToolRunner.perform`: read arguments with `ToolArguments` (`int`, `double`, `bool`, `string`,
   `ints`), which throw `ToolError.invalidArgument` for the model to fix; return a compact `JSONValue` result and a short
   line for the chat ("Resized to 1920 × 1080").
3. If it changes the document, call `requireEditable()` first, and make the change one undo step: call an existing
   session function that already wraps itself in `beginEdit(_:)`/`endEdit()`, or wrap it yourself with the name Edit ›
   Undo should show. Operations with sheets of their own get a sheet-free twin in `ProjectController`, as
   `resizeImage(to:)` and `exportPNGFile(named:)` are for Image Size and Export PNG.
4. Mention it in the system prompt if the model needs to know when to use it, and add tests for its pure parts to
   `CompositorTests/AssistantTests.swift`.

Anything a tool would save in the project needs a format version bump (see [project-format.md](project-format.md)).
