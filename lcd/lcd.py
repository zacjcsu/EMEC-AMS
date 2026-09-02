# lcd/lcd.py

from lcd.RGB1602 import RGB1602

class LCD:
    def __init__(self):
        self.lcd = RGB1602(16, 2)

    def display(self, line1="", line2="", color="white"):
        if isinstance(line1, str) and '\n' in line1:
            parts = line1.split('\n')
            line1 = parts[0]
            line2 = parts[1] if len(parts) > 1 else ""

        color_map = {
            "green": (0, 255, 0),
            "red": (255, 0, 0),
            "yellow": (255, 100, 0),
            "gray": (80, 80, 80),
            "white": (255, 255, 255)
        }

        rgb = color_map.get(color, (255, 255, 255))
        self.lcd.setRGB(*rgb)

        self.lcd.clear()
        self.lcd.setCursor(0, 0)
        self.lcd.printout(str(line1)[:16])
        self.lcd.setCursor(0, 1)
        self.lcd.printout(str(line2)[:16])

    def clear(self):
        self.lcd.clear()

    def set_color(self, r, g, b):
        self.lcd.setRGB(r, g, b)
