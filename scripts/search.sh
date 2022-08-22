#!/usr/bin/env python

import os
import zipfile
import subprocess
import tarfile
import tempfile
import sys
import random
import math
import curses
import threading
import time
from io import BytesIO


# TODO: ignore results on external media not plugged in

DB_PATH = "/media/fat/search.db"
CMD_INTERFACE = "/dev/MiSTer_cmd"
MGL_PATH = "/tmp/search_launcher.mgl"

MGL_MAP = (
    ("ATARI2600", "_Console/Atari7800", (({".a78", ".a26", ".bin"}, 1, "f", 1),)),
    ("ATARI7800", "_Console/Atari7800", (({".a78", ".a26", ".bin"}, 1, "f", 1),)),
    ("AtariLynx", "_Console/AtariLynx", (({".lnx"}, 1, "f", 0),)),
    ("C64", "_Computer/C64", (({".prg", ".crt", ".reu", ".tap"}, 1, "f", 1),)),
    (
        "Coleco",
        "_Console/ColecoVision",
        (({".col", ".bin", ".rom", ".sg"}, 1, "f", 0),),
    ),
    ("GAMEBOY2P", "_Console/Gameboy2P", (({".gb", ".gbc"}, 1, "f", 1),)),
    ("GAMEBOY", "_Console/Gameboy", (({".gb", ".gbc"}, 1, "f", 1),)),
    ("GBA2P", "_Console/GBA2P", (({".gba"}, 1, "f", 0),)),
    ("GBA", "_Console/GBA", (({".gba"}, 1, "f", 0),)),
    ("Genesis", "_Console/Genesis", (({".bin", ".gen", ".md"}, 1, "f", 0),)),
    ("MegaCD", "_Console/MegaCD", (({".cue", ".chd"}, 1, "s", 0),)),
    (
        "NeoGeo",
        "_Console/NeoGeo",
        (({".neo"}, 1, "f", 1), ({".iso", ".bin"}, 1, "s", 1)),
    ),
    ("NES", "_Console/NES", (({".nes", ".fds", ".nsf"}, 1, "f", 0),)),
    ("PSX", "_Console/PSX", (({".cue", ".chd"}, 1, "s", 1),)),
    ("S32X", "_Console/S32X", (({".32x"}, 1, "f", 0),)),
    ("SMS", "_Console/SMS", (({".sms", ".sg"}, 1, "f", 1), ({".gg"}, 1, "f", 2))),
    ("SNES", "_Console/SNES", (({".sfc", ".smc"}, 2, "f", 0),)),
    (
        "TGFX16-CD",
        "_Console/TurboGrafx16",
        (({".cue", ".chd"}, 1, "s", 0),),
    ),
    (
        "TGFX16",
        "_Console/TurboGrafx16",
        (
            ({".pce", ".bin"}, 1, "f", 0),
            ({".sgx"}, 1, "f", 1),
        ),
    ),
    ("VECTREX", "_Console/Vectrex", (({".ovr", ".vec", ".bin", ".rom"}, 1, "f", 1),)),
    ("WonderSwan", "_Console/WonderSwan", (({".wsc", ".ws"}, 1, "f", 1),)),
    ("_Arcade", "", (({".mra"}, 0, "", 0),)),
)

GAMES_FOLDERS = (
    "/media/fat",
    "/media/usb0",
    "/media/usb1",
    "/media/usb2",
    "/media/usb3",
    "/media/usb4",
    "/media/usb5",
    "/media/fat/cifs",
)


def get_system(name: str):
    for system in MGL_MAP:
        if name.lower() == system[0].lower():
            return system


def match_system_file(system, filename):
    _, ext = os.path.splitext(filename)
    for type in system[2]:
        if ext.lower() in type[0]:
            return type


def random_item(list):
    return list[random.randint(0, len(list) - 1)]


def get_system(name: str):
    for system in MGL_MAP:
        if name.lower() == system[0].lower():
            return system


def generate_mgl(rbf, delay, type, index, path):
    mgl = '<mistergamedescription>\n\t<rbf>{}</rbf>\n\t<file delay="{}" type="{}" index="{}" path="../../../..{}"/>\n</mistergamedescription>\n'
    return mgl.format(rbf, delay, type, index, path)


def to_mgl_args(system, match, full_path):
    return (
        system[1],
        match[1],
        match[2],
        match[3],
        full_path,
    )


def create_mgl_file(system_name, path):
    system = get_system(system_name)
    with open(MGL_PATH, "w") as mgl:
        mgl.write(
            generate_mgl(*to_mgl_args(system, match_system_file(system, path), path))
        )
    return mgl


# {<system name>: <full games path>[]}
def get_system_paths():
    systems = {}

    def add_system(name, folder):
        path = os.path.join(folder, name)
        if name in systems:
            systems[name].append(path)
        else:
            systems[name] = [path]

    def find_folders(path):
        if not os.path.exists(path) or not os.path.isdir(path):
            return False

        for folder in os.listdir(path):
            system = get_system(folder)
            if os.path.isdir(os.path.join(path, folder)) and system:
                add_system(system[0], path)

        return True

    for games_path in GAMES_FOLDERS:
        parent = find_folders(games_path)
        if not parent:
            break

        for subpath in os.listdir(games_path):
            if subpath.lower() == "games":
                find_folders(os.path.join(games_path, subpath))

    return systems


# return a generator for all valid system roms
# (<full path>, <system>, <name>)
def get_system_files(name, folder):
    system = get_system(name)

    for root, _, files in os.walk(folder):
        for filename in files:
            path = os.path.join(root, filename)

            if filename.lower().endswith(".zip") and zipfile.is_zipfile(path):
                # zip files
                for zip_path in zipfile.ZipFile(path).namelist():
                    match = match_system_file(system, zip_path)
                    if match:
                        full_path = os.path.join(path, zip_path)
                        game_name, _ = os.path.splitext(os.path.basename(zip_path))
                        yield (full_path, game_name)

            else:
                # regular files
                match = match_system_file(system, filename)
                if match is not None:
                    game_name, _ = os.path.splitext(filename)
                    yield (path, game_name)


class Database:
    def __init__(self):
        self.indexes = []
        self.counts = []
        self.ready = False
        self.load_thread = None
        self.search_ready = False
        self.search_results = []
        self.search_thread = None

    # create new index db file, yields at progress points
    def generate(self):
        system_paths = get_system_paths()
        count_index = ""

        paths_total = 0
        for paths in system_paths.values():
            paths_total += len(paths)

        tar = tarfile.open(DB_PATH, "w:")

        def add(name, s: str):
            info = tarfile.TarInfo(name)
            info.size = len(s)
            tar.addfile(info, BytesIO(s.encode("utf-8")))

        for system in sorted(system_paths.keys()):
            path_index = ""
            name_index = ""
            count = 0

            for system_path in system_paths[system]:
                yield system, system_path, paths_total

                for file_path, name in get_system_files(system, system_path):
                    path_index += file_path + "\n"
                    name_index += name + "\n"
                    count += 1

            add(system + "__path", path_index)
            add(system + "__name", name_index)
            count_index += f"{system}\t{count}\n"

        add("_count", count_index)
        tar.close()

    def exists(self):
        return os.path.exists(DB_PATH)

    def load(self):
        if self.ready:
            return

        tar = tarfile.open(DB_PATH, "r:")
        for path_file in [x for x in tar.getnames() if x.endswith("__path")]:
            system = path_file.split("__")[0]
            name_file = system + "__name"
            self.indexes.append(
                (
                    system,
                    tar.extractfile(path_file).read().decode("utf-8"),
                    tar.extractfile(name_file).read().decode("utf-8"),
                )
            )

        count_file = tar.extractfile("_count").read().decode("utf-8").splitlines()
        for line in count_file:
            system, count = line.split("\t")
            self.counts.append((system, int(count)))

        self.ready = True
        tar.close()

    def load_in_background(self):
        if self.ready:
            return

        self.load_thread = threading.Thread(target=self.load)
        self.load_thread.start()

    def search(self, query: str, filtered=True):
        while not self.ready:
            time.sleep(0.1)

        self.search_ready = False
        results = []
        query_words = query.split()

        if len(query_words) == 0:
            return []

        for system, paths, names in self.indexes:
            name_file = tempfile.NamedTemporaryFile()
            name_file.write(names.encode("utf-8"))

            grep = subprocess.run(
                ["grep", "-in", query_words[0], name_file.name],
                text=True,
                capture_output=True,
            )
            grep_output = grep.stdout.splitlines()

            if len(query_words) > 1:
                for word in query_words[1:]:
                    grep_output = [
                        x for x in grep_output if word.casefold() in x.casefold()
                    ]

            grep_results = []
            for line in grep_output:
                line_num, name = line.split(":", 1)
                grep_results.append((int(line_num), name))

            if len(grep_results) > 0:
                for line_num, name in grep_results:
                    results.append((system, paths[line_num - 1], name))

        if filtered:
            names = set()
            filtered_results = []
            for result in results:
                if result[2] in name:
                    continue
                names.add(result[2])
                filtered_results.append(result)
            filtered_results.sort(key=lambda x: x[2])
            results = filtered_results

        self.search_results = results
        self.search_ready = True
        return results

    def search_in_background(self, query: str, filtered=True):
        self.search_thread = threading.Thread(
            target=self.search, args=(query, filtered)
        )
        self.search_thread.start()

    def count(self, system=None):
        if not system:
            return sum(x[1] for x in self.counts)


def launch_game(system_name, path):
    if system_name == "_Arcade":
        launch_path = path
    else:
        mgl = create_mgl_file(system_name, path)
        launch_path = mgl.name

    os.system(f'echo "load_core {launch_path}" > {CMD_INTERFACE}')
    sys.exit(0)


def get_curses_colors():
    curses.start_color()
    curses.init_pair(1, curses.COLOR_BLUE, curses.COLOR_WHITE)
    curses.init_pair(2, curses.COLOR_WHITE, curses.COLOR_WHITE)
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_WHITE)
    curses.init_pair(4, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(5, curses.COLOR_YELLOW, curses.COLOR_BLUE)

    return {
        "LBOG": curses.color_pair(1) | curses.A_BOLD,
        "WOG": curses.color_pair(2) | curses.A_BOLD,
        "BOG": curses.color_pair(3),
        "WOB": curses.color_pair(4) | curses.A_BOLD,
        "DGOG": curses.color_pair(3) | curses.A_BOLD,
        "YOB": curses.color_pair(5) | curses.A_BOLD,
    }


def draw_dialog_box(stdscr, colors, width: int, height: int, title: str):
    screen_height, screen_width = stdscr.getmaxyx()

    dialog_x = int((screen_width // 2) - (width // 2) - width % 2)
    dialog_y = int((screen_height // 2) - (height // 2) - height % 2)

    pos_x = dialog_x
    pos_y = dialog_y

    stdscr.addch(pos_y, pos_x, curses.ACS_ULCORNER, colors["WOG"])
    pos_x += 1
    line_len = (width // 2) - (len(title) // 2)
    for _ in range(0, line_len):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["WOG"])
        pos_x += 1
    stdscr.addstr(pos_y, pos_x, title, colors["LBOG"])
    pos_x += len(title)
    for _ in range(0, line_len):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["WOG"])
        pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_URCORNER, colors["BOG"])

    hline_width = (line_len * 2) + len(title)

    pos_y += 1
    pos_x = dialog_x
    for _ in range(0, height - 2):
        stdscr.addch(pos_y, pos_x, curses.ACS_VLINE, colors["WOG"])
        pos_x += 1
        stdscr.addstr(pos_y, pos_x, " " * hline_width, colors["WOG"])
        pos_x += hline_width
        stdscr.addch(pos_y, pos_x, curses.ACS_VLINE, colors["BOG"])
        pos_x = dialog_x
        pos_y += 1

    stdscr.addch(pos_y, pos_x, curses.ACS_LLCORNER, colors["WOG"])
    pos_x += 1
    for _ in range(0, hline_width):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["BOG"])
        pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_LRCORNER, colors["BOG"])

    return dialog_y, dialog_x


def draw_search_buttons(
    stdscr, colors, offset_y, offset_x, dialog_width, dialog_height, focused
):
    # buttons separator line
    pos_x = offset_x
    pos_y = offset_y + dialog_height - 3
    stdscr.addch(pos_y, pos_x, curses.ACS_LTEE, colors["WOG"])
    pos_x += 1
    for _ in range(0, dialog_width - 1):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["WOG"])
        pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_RTEE, colors["BOG"])

    # buttons
    pos_x = offset_x + 15
    pos_y += 1

    def print_button(text, width, button_focused):
        nonlocal pos_x
        pad = math.ceil((width - len(text)) / 2)
        stdscr.addch(
            pos_y,
            pos_x,
            "<",
            colors["WOB"] if button_focused else colors["BOG"],
        )
        pos_x += 1
        stdscr.addstr(
            pos_y,
            pos_x,
            " " * pad,
            colors["WOB"] if button_focused else colors["WOG"],
        )
        pos_x += pad
        stdscr.addstr(
            pos_y,
            pos_x,
            text,
            colors["YOB"] if button_focused else colors["DGOG"],
        )
        pos_x += len(text)
        stdscr.addstr(
            pos_y,
            pos_x,
            " " * pad,
            colors["WOB"] if button_focused else colors["WOG"],
        )
        pos_x += pad
        stdscr.addch(
            pos_y,
            pos_x,
            ">",
            colors["WOB"] if button_focused else colors["BOG"],
        )
        pos_x += 1

    values = ("Search", "Advanced", "Exit")
    for i in range(0, 3):
        print_button(values[i], 7, focused == i)
        pos_x += 8


def draw_input_box(stdscr, colors, offset_y, offset_x, container_width, text):
    pos_x = offset_x + 2
    pos_y = offset_y + 1

    stdscr.addch(pos_y, pos_x, curses.ACS_ULCORNER, colors["BOG"])
    pos_x += 1
    for _ in range(0, container_width - 5):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["BOG"])
        pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_URCORNER, colors["WOG"])

    pos_y += 1
    pos_x = offset_x + 2
    stdscr.addch(pos_y, pos_x, curses.ACS_VLINE, colors["BOG"])
    pos_x += 1
    stdscr.addch(pos_y, pos_x, " ", colors["BOG"])
    pos_x += 1

    input_start = (pos_y, pos_x)

    stdscr.addstr(
        pos_y,
        pos_x,
        " " * (container_width - 7),
        colors["BOG"],
    )
    pos_x += container_width - 7
    stdscr.addch(pos_y, pos_x, " ", colors["BOG"])
    pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_VLINE, colors["WOG"])

    pos_x = offset_x + 2
    pos_y += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_LLCORNER, colors["BOG"])
    pos_x += 1
    for _ in range(0, container_width - 5):
        stdscr.addch(pos_y, pos_x, curses.ACS_HLINE, colors["WOG"])
        pos_x += 1
    stdscr.addch(pos_y, pos_x, curses.ACS_LRCORNER, colors["WOG"])

    stdscr.addstr(input_start[0], input_start[1], text, colors["BOG"])

    return input_start


def _draw_keyboard_input(stdscr, text=""):
    k = 0

    stdscr.clear()
    stdscr.refresh()

    curses.curs_set(1)

    colors = get_curses_colors()

    dialog_height = 14
    dialog_width = 75
    dialog_title = "Search"

    KEYS = (
        ("Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"),
        ("A", "S", "D", "F", "G", "H", "J", "K", "L", "SPC"),
        ("Z", "X", "C", "V", "B", "N", "M", "LAR", "RAR", "DEL"),
    )

    BUTTONS = 2
    KEYBOARD = 1
    focused_element = KEYBOARD
    focused_key = [1, 4]
    focused_button = 0
    input_text = text
    input_cursor = len(input_text)
    max_len = dialog_width - 8

    while k != 27:
        stdscr.erase()

        if k == curses.KEY_DOWN:
            if focused_element == KEYBOARD:
                if focused_key[0] >= 2:
                    focused_element = BUTTONS
                    if focused_key[1] <= 3:
                        focused_button = 0
                    elif focused_key[1] <= 5:
                        focused_button = 1
                    elif focused_key[1] >= 6:
                        focused_button = 2
                else:
                    focused_key[0] += 1
        elif k == curses.KEY_UP:
            if focused_element == BUTTONS:
                focused_element = KEYBOARD
                if focused_button == 0:
                    focused_key[1] = 2
                elif focused_button == 1:
                    focused_key[1] = 4
                elif focused_button == 2:
                    focused_key[1] = 7
            elif focused_element == KEYBOARD:
                if focused_key[0] > 0:
                    focused_key[0] -= 1
        elif k == curses.KEY_RIGHT:
            if focused_element == KEYBOARD:
                if focused_key[1] >= len(KEYS[focused_key[0]]) - 1:
                    focused_key[1] = 0
                else:
                    focused_key[1] += 1
            elif focused_element == BUTTONS:
                if focused_button >= 2:
                    focused_button = 0
                else:
                    focused_button += 1
        elif k == curses.KEY_LEFT:
            if focused_element == KEYBOARD:
                if focused_key[1] <= 0:
                    focused_key[1] = len(KEYS[focused_key[0]]) - 1
                else:
                    focused_key[1] -= 1
            elif focused_element == BUTTONS:
                if focused_button <= 0:
                    focused_button = 2
                else:
                    focused_button -= 1
        elif k == curses.KEY_ENTER or k == 10 or k == 13:
            if focused_element == KEYBOARD:
                key_at = KEYS[focused_key[0]][focused_key[1]]
                text_start = input_text[:input_cursor]
                text_end = input_text[input_cursor:]
                if key_at == "SPC":
                    if len(input_text) < max_len:
                        input_text = text_start + " " + text_end
                        input_cursor += 1
                elif key_at == "DEL":
                    if input_cursor > 0:
                        input_text = text_start[:-1] + text_end
                        input_cursor -= 1
                elif key_at == "LAR":
                    if input_cursor > 0:
                        input_cursor -= 1
                elif key_at == "RAR":
                    if input_cursor < len(input_text):
                        input_cursor += 1
                else:
                    if len(input_text) < max_len:
                        input_text = text_start + key_at.lower() + text_end
                        input_cursor += 1
            elif focused_element == BUTTONS:
                return (focused_button, input_text)

        input_start = (0, 0)

        dialog_y, dialog_x = draw_dialog_box(
            stdscr, colors, dialog_width, dialog_height, dialog_title
        )

        draw_search_buttons(
            stdscr,
            colors,
            dialog_y,
            dialog_x,
            dialog_width,
            dialog_height,
            focused_button if focused_element == BUTTONS else -1,
        )

        def draw_keyboard(focused_row=-1, focused_col=-1):
            pos_x = dialog_x + 4
            pos_y = dialog_y + 5

            for fr, row in enumerate(KEYS):
                for fc, key in enumerate(row):
                    if fr == focused_row and fc == focused_col:
                        selected = True
                    else:
                        selected = False

                    if key == "LAR":
                        key = curses.ACS_LARROW
                    elif key == "RAR":
                        key = curses.ACS_RARROW

                    stdscr.addch(
                        pos_y, pos_x, "[", colors["WOB"] if selected else colors["BOG"]
                    )
                    pos_x += 1
                    if type(key) is str and len(key) == 3:
                        stdscr.addstr(
                            pos_y,
                            pos_x,
                            key,
                            colors["YOB"] if selected else colors["BOG"],
                        )
                        pos_x += 3
                    else:
                        stdscr.addch(
                            pos_y,
                            pos_x,
                            " ",
                            colors["YOB"] if selected else colors["BOG"],
                        )
                        pos_x += 1
                        stdscr.addch(
                            pos_y,
                            pos_x,
                            key,
                            colors["YOB"] if selected else colors["BOG"],
                        )
                        pos_x += 1
                        stdscr.addch(
                            pos_y,
                            pos_x,
                            " ",
                            colors["YOB"] if selected else colors["BOG"],
                        )
                        pos_x += 1
                    stdscr.addch(
                        pos_y, pos_x, "]", colors["WOB"] if selected else colors["BOG"]
                    )
                    pos_x += 3
                pos_x = dialog_x + 4
                pos_y += 2

        if focused_element == KEYBOARD:
            draw_keyboard(focused_key[0], focused_key[1])
        else:
            draw_keyboard(-1, -1)

        input_start = draw_input_box(
            stdscr, colors, dialog_y, dialog_x, dialog_width, input_text
        )

        stdscr.move(input_start[0], input_start[1] + input_cursor)

        stdscr.refresh()
        k = stdscr.getch()


def display_keyboard_input(db: Database, text=""):
    button, text = curses.wrapper(_draw_keyboard_input, text)
    if button == 0:
        if text == "":
            display_keyboard_input(db)
            return
        display_search_results(db, text)


def dialog_env():
    return dict(os.environ, DIALOGRC="/media/fat/Scripts/.dialogrc")


def display_text_input(db: Database, query=""):
    args = [
        "dialog",
        "--title",
        "Search",
        "--ok-label",
        "Search",
        "--cancel-label",
        "Exit",
        "--extra-button",
        "--extra-label",
        "Advanced",
        "--inputbox",
        "",
        "7",
        "75",
        query,
    ]

    result = subprocess.run(args, stderr=subprocess.PIPE, env=dialog_env())

    button = result.returncode
    query = result.stderr.decode()

    if button == 0:
        display_search_results(db, query)


def display_message(msg, info=False, height=5, title="Search"):
    if info:
        type = "--infobox"
    else:
        type = "--msgbox"

    args = [
        "dialog",
        "--title",
        title,
        "--ok-label",
        "Ok",
        type,
        msg,
        str(height),
        "75",
    ]

    subprocess.run(args, env=dialog_env())


def _draw_search_loading(stdscr, db: Database, query=""):
    stdscr.clear()
    stdscr.refresh()

    colors = get_curses_colors()

    dialog_width = max(len(query) + 4, 24)
    dialog_height = 4

    anim_frames = [
        "|",
        "/",
        "-",
        "\\",
    ]
    active_frame = 0

    curses.curs_set(0)

    db.search_in_background(query)

    while not db.search_ready:
        stdscr.erase()

        dialog_y, dialog_x = draw_dialog_box(
            stdscr, colors, dialog_width, dialog_height, "Searching..."
        )

        stdscr.addstr(
            dialog_y + 1,
            dialog_x + (dialog_width // 2) - (len(query) // 2),
            query,
            colors["BOG"],
        )

        stdscr.addstr(
            dialog_y + 2,
            dialog_x + (dialog_width // 2),
            anim_frames[active_frame],
            colors["BOG"],
        )
        active_frame = (active_frame + 1) % len(anim_frames)

        stdscr.refresh()
        time.sleep(0.08)


def draw_search_loading(db: Database, query=""):
    curses.wrapper(_draw_search_loading, db, query)


def display_search_results(db: Database, query: str):
    # TODO: random button
    draw_search_loading(db, query)

    if len(db.search_results) == 0:
        display_message("No results found.")
        display_keyboard_input(db, query)
        return

    results = db.search_results
    total_results = len(db.search_results)
    max_results = 1000
    if total_results > max_results:
        results = results[:max_results]

    args = [
        "dialog",
        "--title",
        "Search",
        "--ok-label",
        "Launch",
        "--cancel-label",
        "Cancel",
        "--menu",
        f"Found {total_results} results. Select game to launch:",
        "20",
        "75",
        "20",
    ]

    for i, result in enumerate(results, start=1):
        args.append(str(i))
        args.append(f"{result[2]} [{result[0]}]")

    result = subprocess.run(args, stderr=subprocess.PIPE, env=dialog_env())

    index = str(result.stderr.decode())
    button = result.returncode

    if button == 0:
        selected = results[int(index) - 1]
        launch_game(selected[0], selected[1])
    else:
        display_keyboard_input(db, query)


def display_generate_db(db: Database):
    display_message(
        "This script will now create an index of all your games. This only happens once, but it can 1-2 minutes for a large collection.",
        height=6,
        title="Creating Index",
    )

    def display_progress(msg, pct):
        args = [
            "dialog",
            "--title",
            "Creating Index...",
            "--gauge",
            msg,
            "6",
            "75",
            str(pct),
        ]
        progress = subprocess.Popen(args, env=dialog_env(), stdin=subprocess.PIPE)
        progress.communicate("".encode())

    for i, v in enumerate(db.generate()):
        pct = math.ceil(i / v[2] * 100)
        display_progress(f"Scanning {v[0]} ({v[1]})", pct)

    display_message(
        f"Index generated successfully. Found {db.count()} games.",
        title="Indexing Complete",
    )


if __name__ == "__main__":
    db = Database()
    if not db.exists():
        display_generate_db(db)
    db.load_in_background()
    display_keyboard_input(db)
