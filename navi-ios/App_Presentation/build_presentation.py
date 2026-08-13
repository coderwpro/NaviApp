"""Builds the NaviRemote app overview deck.

Re-runnable: drop files into media/ and run it again, and they are embedded automatically.
Anything missing is left as a labelled placeholder, so the deck is always complete.

    media/demo_language.mp4   → embedded on the Word Play demo slide
    media/demo_story.mp4      → embedded on the Story demo slide
    media/controls_*.png      → laid out across the control screenshot slides
    media/wordplay_*.png      → Word Play screenshots
    media/story_*.png         → Story screenshots
"""
from pathlib import Path
from pptx import Presentation
from pptx.util import Emu, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

HERE = Path(__file__).parent
MEDIA = HERE / "media"
OUT = HERE / "NaviRemote_App_Overview.pptx"

W, H = Emu(9144000), Emu(5143500)              # 16:9, same as the internship deck
BLUE, TEAL = RGBColor(0x05, 0x8D, 0xC7), RGBColor(0x15, 0x81, 0x58)
ORANGE, PURPLE = RGBColor(0xED, 0x56, 0x1B), RGBColor(0x7B, 0x4B, 0xC4)
INK, GREY, PAPER = RGBColor(0x1A, 0x1A, 0x1A), RGBColor(0x66, 0x66, 0x66), RGBColor(0xFF, 0xFF, 0xFF)
FONT = "Arial"

prs = Presentation()
prs.slide_width, prs.slide_height = W, H
BLANK = prs.slide_layouts[6]


def bg(slide, colour):
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = colour


def tbox(slide, x, y, w, h, anchor=MSO_ANCHOR.TOP):
    tf = slide.shapes.add_textbox(Emu(x), Emu(y), Emu(w), Emu(h)).text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    return tf


def line(tf, text, size, colour=INK, bold=False, after=8, first=False, align=PP_ALIGN.LEFT):
    p = tf.paragraphs[0] if first else tf.add_paragraph()
    p.alignment, p.space_after = align, Pt(after)
    r = p.add_run()
    r.text, r.font.size, r.font.bold, r.font.name = text, Pt(size), bold, FONT
    r.font.color.rgb = colour
    return p


def bar(slide, colour=BLUE, y=1_180_000):
    s = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Emu(720_000), Emu(y), Emu(980_000), Emu(58_000))
    s.fill.solid(); s.fill.fore_color.rgb = colour
    s.line.fill.background(); s.shadow.inherit = False


def header(slide, title, colour=BLUE, sub=None):
    tf = tbox(slide, 720_000, 560_000, 7_700_000, 640_000)
    line(tf, title, 32, INK, True, 0, first=True)
    bar(slide, colour)
    if sub:
        st = tbox(slide, 720_000, 1_290_000, 7_700_000, 320_000)
        line(st, sub, 14, GREY, False, 0, first=True)


def divider(label, colour):
    s = prs.slides.add_slide(BLANK); bg(s, colour)
    tf = tbox(s, 720_000, 0, 7_700_000, H, anchor=MSO_ANCHOR.MIDDLE)
    line(tf, label, 46, PAPER, True, 0, first=True)
    return s


def bullets(title, items, colour=BLUE, sub=None, note=None):
    s = prs.slides.add_slide(BLANK); bg(s, PAPER)
    header(s, title, colour, sub)
    body = tbox(s, 720_000, 1_720_000, 7_700_000, 2_900_000)
    first = True
    for it in items:
        if isinstance(it, tuple):
            line(body, it[0], 17, INK, True, 1, first=first)
            line(body, it[1], 13, GREY, False, 10)
        else:
            line(body, it, 17, INK, False, 10, first=first)
        first = False
    if note:
        s.notes_slide.notes_text_frame.text = note
    return s


def placeholder(slide, x, y, w, h, label, hint, colour=BLUE):
    """A labelled drop zone, used when the real media is not in media/ yet."""
    box = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Emu(x), Emu(y), Emu(w), Emu(h))
    box.fill.solid(); box.fill.fore_color.rgb = RGBColor(0xF4, 0xF6, 0xF8)
    box.line.color.rgb = colour
    box.line.width = Pt(1.5)
    box.line.dash_style = 4                      # dashed
    box.shadow.inherit = False
    tf = box.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    line(tf, label, 18, colour, True, 4, first=True, align=PP_ALIGN.CENTER)
    line(tf, hint, 11, GREY, False, 0, align=PP_ALIGN.CENTER)


def media_slide(title, filename, label, hint, colour, note=None):
    """Embeds media/<filename> if present; otherwise leaves a drop zone."""
    s = prs.slides.add_slide(BLANK); bg(s, PAPER)
    header(s, title, colour)
    x, y, w, h = 1_100_000, 1_640_000, 6_950_000, 3_050_000
    path = MEDIA / filename
    if path.exists():
        try:
            if path.suffix.lower() in {".mp4", ".mov", ".m4v"}:
                poster = MEDIA / (path.stem + "_poster.png")
                s.shapes.add_movie(str(path), Emu(x), Emu(y), Emu(w), Emu(h),
                                   poster_frame_image=str(poster) if poster.exists() else None)
            else:
                s.shapes.add_picture(str(path), Emu(x), Emu(y), height=Emu(h))
        except Exception as exc:                 # keep the deck buildable whatever happens
            placeholder(s, x, y, w, h, label, f"could not embed {filename}: {exc}", colour)
    else:
        placeholder(s, x, y, w, h, label, hint, colour)
    if note:
        s.notes_slide.notes_text_frame.text = note
    return s


def gallery(title, pattern, colour, hints):
    """Up to three screenshots side by side, or three labelled drop zones."""
    s = prs.slides.add_slide(BLANK); bg(s, PAPER)
    header(s, title, colour)
    found = sorted(MEDIA.glob(pattern))
    x0, y, w, h, gap = 900_000, 1_680_000, 2_260_000, 2_950_000, 260_000
    for i in range(3):
        x = x0 + i * (w + gap)
        if i < len(found):
            try:
                s.shapes.add_picture(str(found[i]), Emu(x), Emu(y), height=Emu(h))
                continue
            except Exception:
                pass
        placeholder(s, x, y, w, h, f"Screenshot {i + 1}",
                    hints[i] if i < len(hints) else "", colour)
    return s


# ═══════════════════════════════════════════════════════════════════════════
# Title
s = prs.slides.add_slide(BLANK); bg(s, PAPER)
tf = tbox(s, 720_000, 1_450_000, 7_700_000, 1_900_000)
line(tf, "Navi Remote", 54, INK, True, 4, first=True)
line(tf, "iPhone app for the Navi quadruped — control, language learning, storytelling", 19, GREY, False, 0)
bar(s, BLUE, y=2_900_000)

bullets("What It Is", [
    ("A native iOS app", "Swift · SwiftUI · CoreBluetooth — the phone talks straight to the robot"),
    ("No laptop, no server, no web page", "install once over a cable, then it runs standalone"),
    ("Three screens", "Control · Word Play · Stories"),
    ("One Bluetooth link, shared", "one connection, one safety gate, one e-stop across all three"),
], TEAL)

bullets("Architecture", [
    ("RootView", "owns the BLE link and the speech engine; stops both when you switch tabs"),
    ("NaviBLE", "scan, connect, 20 Hz drive loop, every safety limit"),
    ("SpeechEngine", "OpenAI text-to-speech, on-device fallback, prefetching"),
    ("Tutor · StoryCompanion · StoryComposer", "the three places a language model is used"),
    ("NaviProtocol", "frames and limits, with no CoreBluetooth import — testable on its own"),
], TEAL)

# ── Control ──────────────────────────────────────────────────────────────
divider("Control", BLUE)

bullets("Connection", [
    ("Scan and connect", "filters on the advertised name; refuses if more than one Navi is in range"),
    ("Automatic retry and reconnect", "8-second timeout, five attempts, reconnects if a session drops"),
    ("Releases stale links", "clears connections iOS holds after a force-quit — no more power-cycling"),
    ("Signal strength", "RSSI on screen, warning below −85 dBm"),
], BLUE, note="About a third of connection attempts fail on this robot. That is robot-side.")

bullets("Telemetry", [
    ("Battery, e-stop bit, motion state", "parsed from the status frame at ~5 Hz"),
    ("action_id shown but never gated on", "one healthy unit reports 625"),
    ("Temperatures and frame count", "plus how long ago the last frame arrived"),
    ("Driving is locked until telemetry arrives", "with an explicit override for units that never send it"),
], BLUE)

bullets("Driving", [
    ("Hold-to-drive pad", "forward, back, turn left, turn right"),
    ("Speed 1–127, presets at 30 / 100 / 127", "clamped in the driver, not just the UI"),
    ("Posture controls", "raise, bow, twist — floored at 17, below which nothing moves"),
    ("Diagnostics", "vy probe for the unconfirmed axis, and a raw unclamped byte tester"),
], BLUE)

gallery("Control — Screens", "controls_*.png", BLUE,
        ["Connection + telemetry", "Safety gate + drive pad", "Skills, voice, log"])

bullets("Voice Control", [
    ("Speech recognition on device", "keyword matching first, so it works with no internet"),
    ("The model only classifies", "one label from a fixed list — never a speed, an axis or a byte"),
    ("Sequences", "\"sit down then wag your tail\" runs as two commands"),
], BLUE)

bullets("Safety — Enforced in Code", [
    ("Every axis clamped to ±127", "128 and above are negative on the wire; the robot would reverse"),
    ("Voice motion is time-limited", "capped at 2 seconds, in the driver"),
    ("\"Stop\" never reaches the model", "matched on partial speech, before any network call"),
    ("E-stop reachable on every screen", "never covered, never disabled"),
    ("Stops on backgrounding, lost focus, dropped link", "and a 30-second watchdog behind all of it"),
], ORANGE, note="If code can guarantee it, don't ask a model to.")

# ── Word Play ────────────────────────────────────────────────────────────
divider("Word Play", TEAL)

bullets("Word Play — The Idea", [
    ("The phone becomes the robot's face", "put it on the robot's back; landscape is eyes only"),
    ("Everything is spoken", "a young child may not read, and the phone is out of reach"),
    ("Spanish, French, Mandarin", "words, pronunciation, and everyday phrases"),
    ("Correct answers make the robot celebrate", "in place only — it never walks out from under the phone"),
], TEAL)

bullets("The Conversation", [
    "Start → \"Hello! I am Pip. I can teach you a new language today.\"",
    "\"Which language would you like to learn?\" → spoken answer",
    "Greeting in that language → \"What would you like to do?\"",
    "Words · Speaking · Phrases → the lesson begins",
    "Say \"I don't know\" and Pip gives a clue, not the answer",
], TEAL)

bullets("Teaching Behaviour", [
    ("Pip is a teacher, not a quiz", "warm, specific praise; never says a child is wrong"),
    ("Two attempts, then the answer", "wrong guesses and \"I don't know\" share the count"),
    ("Lenient marking", "homophones accepted — \"sun\"/\"son\", and Mandarin tone is ignored"),
    ("Instant acknowledgement", "\"Yes!\" plays while the real reply is still being written"),
], TEAL)

media_slide("Word Play — Demo", "demo_language.mp4", "▶  VIDEO DEMO",
            "Drop demo_language.mp4 into the media folder and rebuild,\n"
            "or drag a video onto this box in PowerPoint", TEAL,
            note="Show: language chosen by voice, a correct answer, the robot celebrating.")

gallery("Word Play — Screens", "wordplay_*.png", TEAL,
        ["Eyes + Start", "Portrait, mid-lesson", "Landscape face mode"])

# ── Stories ──────────────────────────────────────────────────────────────
divider("Stories", PURPLE)

bullets("Story Time — The Idea", [
    ("Bedtime storytelling", "\"Hello! I'm Pip, your storyteller.\""),
    ("The child picks the subject", "asked out loud, answered out loud"),
    ("Ten written stories", "Aesop, Grimm, Andersen — simplified, each under five minutes"),
    ("Anything else is written on the spot", "a two-minute story about whatever they asked for"),
], PURPLE)

bullets("How a Story Is Told", [
    ("Nine emotions", "each drives speech rate, pitch, delivery instruction, and the eyes"),
    ("Movement on every sentence", "ten in-place combinations, never the same one twice running"),
    ("Questions mid-story", "Pip responds to what the child actually answered"),
    ("It winds down", "no tension in the last two beats, and the robot goes still"),
], PURPLE)

bullets("After the Story", [
    ("\"Would you like another?\"", "not a yes/no question"),
    ("\"I want a princess\" → a princess story", "a new subject is heard as a new subject"),
    ("\"Yes\" → another in the same spirit", "same subject, new characters, never a repeat"),
    ("Anything unclear ends gently", "at bedtime, silence most likely means asleep"),
], PURPLE)

media_slide("Stories — Demo", "demo_story.mp4", "▶  VIDEO DEMO",
            "Drop demo_story.mp4 into the media folder and rebuild,\n"
            "or drag a video onto this box in PowerPoint", PURPLE,
            note="Show: asking for a subject, the story being written, movement during narration.")

gallery("Stories — Screens", "story_*.png", PURPLE,
        ["Eyes + Start", "Mid-story, portrait", "Landscape face mode"])

# ── Cross-cutting ────────────────────────────────────────────────────────
divider("Under the Hood", BLUE)

bullets("The Face", [
    ("Drawn as vectors, not images", "almond lids, hazel iris, 56 striations, limbal ring, catchlights"),
    ("Ten eye styles", "each story wears its own — slit pupils for the fox and wolf"),
    ("Five moods", "idle, listening, speaking, happy, unsure"),
    ("Animated on state change", "talking bob, listening swell, thinking tilt, a pop and sparkle when pleased"),
], BLUE)

bullets("The Voice", [
    ("OpenAI text-to-speech", "emotion sent as plain-English delivery instructions"),
    ("On-device fallback", "hunts for premium and enhanced voices, not the robotic default"),
    ("Prefetching", "fixed lines cached at start; the next story beat fetched during the current one"),
    ("Never blocks", "a failed call degrades the voice, it does not stall the conversation"),
], BLUE)

bullets("Where AI Is Used — and Where It Is Not", [
    ("Used: choosing words", "teaching lines, story text, intent labels"),
    ("Never: anything physical", "no speed, no axis, no duration, no byte"),
    ("Every reply is validated", "labels checked against a fixed list; unknown values dropped"),
    ("Every call has a fallback", "a written line, so a child is never left with silence"),
], ORANGE)

s = prs.slides.add_slide(BLANK); bg(s, BLUE)
tf = tbox(s, 720_000, 0, 7_700_000, H, anchor=MSO_ANCHOR.MIDDLE)
line(tf, "Thank you", 50, PAPER, True, 0, first=True)

MEDIA.mkdir(exist_ok=True)
prs.save(OUT)
print(f"saved {OUT}")
print(f"slides: {len(prs.slides._sldIdLst)}")
found = sorted(p.name for p in MEDIA.iterdir() if p.name != "README.txt")
print(f"media embedded: {found if found else 'none yet — placeholders drawn'}")
