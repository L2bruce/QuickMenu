#!/usr/bin/env python3
"""
Generate macOS AppIcon.icns following macOS Human Interface Guidelines (macOS Sonoma / Sequoia squircle standard).
Automatically detects and removes unwanted outer white/light padding so the icon body fully fills the squircle.
"""
import sys
import os
import shutil
import subprocess
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

def trim_outer_background(img: Image.Image) -> Image.Image:
    """
    Detects if the image has an artificial white/light canvas margin (e.g. from AI generators),
    and precisely crops out the solid icon body using gradient edge detection.
    """
    rgb = img.convert("RGB")
    arr = np.array(rgb)
    gray = arr.mean(axis=2)
    h, w = gray.shape
    
    # Check if edges are predominantly light/white canvas
    edge_mean = np.concatenate([
        gray[0, :], gray[-1, :], gray[:, 0], gray[:, -1]
    ]).mean()
    
    if edge_mean < 230:
        # Edges are already dark/colored, no obvious outer canvas border
        return img
    
    mid_row = gray[h // 2, :]
    diff_row = np.abs(np.diff(mid_row))
    left_edge = int(np.argmax(diff_row[:w // 2])) + 1
    right_edge = int(w // 2 + np.argmax(diff_row[w // 2:])) + 1
    
    mid_col = gray[:, w // 2]
    diff_col = np.abs(np.diff(mid_col))
    top_edge = int(np.argmax(diff_col[:h // 2])) + 1
    
    body_width = right_edge - left_edge
    bottom_edge = top_edge + body_width
    
    if 400 < body_width < 1000 and bottom_edge <= h:
        print(f"🔍 Gradient edge detection: ({left_edge}, {top_edge}, {right_edge}, {bottom_edge}), size: {body_width}x{body_width}")
        return img.crop((left_edge, top_edge, right_edge, bottom_edge))
    
    # Fallback to thresholding
    solid_x = np.where(gray[h // 2, :] < 140)[0]
    solid_y = np.where(gray[:, w // 2] < 140)[0]
    if len(solid_x) > 0 and len(solid_y) > 0:
        left = int(solid_x[0])
        right = int(solid_x[-1])
        top = int(solid_y[0])
        w_body = right - left
        bottom = top + w_body
        return img.crop((left, top, right, bottom))
        
    return img

def create_squircle_icon(input_path, output_icns_path):
    print(f"🎨 Processing input: {input_path}")
    raw_src = Image.open(input_path).convert("RGBA")
    
    # 1. Trim outer padding/white canvas if present
    src = trim_outer_background(raw_src)
    
    # 2. Canvas 1024x1024, standard macOS Sonoma / Sequoia HIG specifications
    canvas_size = 1024
    icon_content_size = 824
    corner_radius = 185
    margin = (canvas_size - icon_content_size) // 2  # 100px
    
    # Square crop center if not exactly square
    w, h = src.size
    min_dim = min(w, h)
    left = (w - min_dim) // 2
    top = (h - min_dim) // 2
    cropped = src.crop((left, top, left + min_dim, top + min_dim))
    resized_content = cropped.resize((icon_content_size, icon_content_size), Image.Resampling.LANCZOS)
    
    # 3. Create squircle mask
    mask = Image.new("L", (icon_content_size, icon_content_size), 0)
    draw_mask = ImageDraw.Draw(mask)
    draw_mask.rounded_rectangle([(0, 0), (icon_content_size, icon_content_size)], radius=corner_radius, fill=255)
    
    # Apply mask
    icon_squircle = Image.new("RGBA", (icon_content_size, icon_content_size), (0, 0, 0, 0))
    icon_squircle.paste(resized_content, (0, 0), mask)
    
    # 4. Create subtle outer rim highlight for crisp edges on dark/light backgrounds
    rim = Image.new("RGBA", (icon_content_size, icon_content_size), (0, 0, 0, 0))
    rim_draw = ImageDraw.Draw(rim)
    rim_draw.rounded_rectangle([(0, 0), (icon_content_size - 1, icon_content_size - 1)], radius=corner_radius, outline=(255, 255, 255, 45), width=2)
    icon_squircle.alpha_composite(rim)
    
    # 5. Drop shadow (standard macOS downward soft shadow)
    shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_box = [margin, margin + 14, margin + icon_content_size, margin + icon_content_size + 14]
    shadow_draw.rounded_rectangle(shadow_box, radius=corner_radius, fill=(0, 0, 0, 80))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=20))
    
    # Combine Shadow + Icon
    final_1024 = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    final_1024.alpha_composite(shadow)
    final_1024.alpha_composite(icon_squircle, (margin, margin))
    
    # 6. Create iconset
    iconset_dir = "/tmp/QuickMenu_AppIcon.iconset"
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir, exist_ok=True)
    
    resolutions = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    
    for filename, size in resolutions:
        resized = final_1024.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, filename), format="PNG")
        
    # Compile to icns
    cmd = ["iconutil", "-c", "icns", iconset_dir, "-o", output_icns_path]
    subprocess.check_call(cmd)
    
    # Clean up iconset
    shutil.rmtree(iconset_dir)
    print(f"✅ Successfully generated filled squircle icon at {output_icns_path}")

if __name__ == "__main__":
    src_file = sys.argv[1] if len(sys.argv) > 1 else "Resources/icon_candidate_1.jpg"
    dest_file = sys.argv[2] if len(sys.argv) > 2 else "Resources/AppIcon.icns"
    create_squircle_icon(src_file, dest_file)
