#!/usr/bin/env python3
"""
multicrop_cv2.py — OpenCV detekce fotografii na naskenovanem obrazku.

Algoritmus: projekcni profily — hledani bilych mezer (separatoru) mezi fotkami.
1) Horizontalni profil → radkove bandy
2) Per-band vertikalni profil → sloupce
3) Cross-band validace (konsistentni mezery)
4) Pro kazdou bunku tight bounding box foreground pixelu

Pouziti:
    python3 multicrop_cv2.py <image_path> [--sensitivity 0.5]
                                          [--min-area 0.04]
                                          [--max-area 0.50]
                                          [--max-count 20]
                                          [--debug]

Vystup: JSON pole na stdout
    [{"x":..,"y":..,"w":..,"h":..,"img_w":..,"img_h":..}]
"""

import sys
import json
import argparse

try:
    import cv2
    import numpy as np
except ImportError as e:
    print(json.dumps({"error": f"Missing dependency: {e}"}), file=sys.stdout)
    sys.exit(1)


DEBUG = False


def dbg(msg):
    if DEBUG:
        print(f"[DBG] {msg}", file=sys.stderr)


def smooth1d(arr, size=5):
    """Jednoduchy klouzavy prumer bez zavislosti na scipy."""
    if size <= 1:
        return arr
    kernel = np.ones(size) / size
    return np.convolve(arr, kernel, mode='same')


def find_gaps(profile, min_pct=0.80, min_width=3, smooth=5):
    """Najdi souvisle oblasti v profilu kde > min_pct pixelu je bile."""
    profile_s = smooth1d(profile, size=smooth)
    mask = profile_s > min_pct
    groups = []
    in_gap = False
    start = 0
    for i in range(len(mask)):
        if mask[i] and not in_gap:
            start = i
            in_gap = True
        elif not mask[i] and in_gap:
            if i - start >= min_width:
                groups.append((start, i - 1))
            in_gap = False
    if in_gap and len(mask) - start >= min_width:
        groups.append((start, len(mask) - 1))
    return groups


def cluster_gap_positions(band_gaps, tolerance=40):
    """
    Najdi vertikalni mezery ktere se vyskytuji ve vice bandech.
    Vraci seznam center konzistentnich mezer.
    """
    all_centers = []
    for bi, gaps in enumerate(band_gaps):
        for g in gaps:
            all_centers.append(((g[0] + g[1]) // 2, bi))

    all_centers.sort(key=lambda x: x[0])
    clusters = []
    for center, bi in all_centers:
        merged = False
        for cl in clusters:
            if abs(center - cl['mean']) < tolerance:
                cl['bands'].add(bi)
                cl['positions'].append(center)
                cl['mean'] = sum(cl['positions']) / len(cl['positions'])
                merged = True
                break
        if not merged:
            clusters.append({
                'mean': center,
                'bands': {bi},
                'positions': [center],
            })

    return sorted(clusters, key=lambda x: x['mean'])


def detect_photos(image_path, sensitivity=0.5, min_area_ratio=0.04,
                  max_area_ratio=0.50, max_count=20):
    """Hlavni detekce pomoci projekcnich profilu."""

    img = cv2.imread(image_path)
    if img is None:
        return {"error": f"Cannot read image: {image_path}"}

    h, w = img.shape[:2]
    total_area = h * w
    min_area = int(total_area * min_area_ratio)
    max_area = int(total_area * max_area_ratio)

    dbg(f"Image: {w}x{h}, total_area={total_area}")

    # ── 1. Downscale pro zpracovani ──────────────────────────────────────
    proc_size = 3000
    scale = min(1.0, proc_size / max(w, h))
    pw = int(w * scale)
    ph = int(h * scale)

    if scale < 1.0:
        proc = cv2.resize(img, (pw, ph), interpolation=cv2.INTER_AREA)
    else:
        proc = img.copy()

    gray = cv2.cvtColor(proc, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)

    dbg(f"Processing: {pw}x{ph} (scale={scale:.4f})")

    # ── 2. Background maska (bile pozadi) ────────────────────────────────
    #    sensitivity 0.1 → bg_thresh ~205 (stridmy)
    #    sensitivity 0.9 → bg_thresh ~232 (zachyti svetlejsi fotky)
    bg_thresh = int(200 + sensitivity * 35)
    bg_mask = (gray > bg_thresh).astype(np.float32)

    dbg(f"Background threshold: {bg_thresh}")

    # ── 3. Horizontalni profil → radkove bandy ──────────────────────────
    row_profile = np.mean(bg_mask, axis=1)
    h_gap_pct = 0.80
    h_gaps = find_gaps(row_profile, min_pct=h_gap_pct, min_width=3)
    h_inner = [g for g in h_gaps if g[0] > 15 and g[1] < ph - 15]

    dbg(f"Horizontal gaps: {len(h_inner)}")

    row_bounds = [0]
    for g in h_inner:
        row_bounds.append((g[0] + g[1]) // 2)
    row_bounds.append(ph)

    dbg(f"Row bands: {list(zip(row_bounds[:-1], row_bounds[1:]))}")

    # ── 4. Per-band vertikalni profil ────────────────────────────────────
    all_band_gaps = []
    for y1, y2 in zip(row_bounds[:-1], row_bounds[1:]):
        band_bg = bg_mask[y1:y2, :]
        col_profile = np.mean(band_bg, axis=0)
        v_gaps = find_gaps(col_profile, min_pct=h_gap_pct, min_width=5)
        v_inner = [g for g in v_gaps if g[0] > 15 and g[1] < pw - 15]
        all_band_gaps.append(v_inner)
        dbg(f"  Band v_gaps: {[(g[0],g[1]) for g in v_inner]}")

    # ── 5. Cross-band konzistence ────────────────────────────────────────
    clusters = cluster_gap_positions(all_band_gaps, tolerance=40)

    # Mezery potvrzene ve >= 2 bandech = spolehlivy grid
    n_bands = len(row_bounds) - 1
    min_confirm = min(2, n_bands)
    consistent_centers = [
        int(cl['mean'])
        for cl in clusters
        if len(cl['bands']) >= min_confirm
    ]
    dbg(f"Consistent gap centers: {consistent_centers}")

    # ── 6. Pro kazdy band: sestav sloupce a extrahuj fotky ───────────────
    photos = []

    for bi, (y1, y2) in enumerate(zip(row_bounds[:-1], row_bounds[1:])):
        # Zakladni sloupce z konzistentnich mezer
        col_bounds = sorted(set([0] + consistent_centers + [pw]))

        # Pridej band-specificke mezery pro siroke bunky
        band_gaps = all_band_gaps[bi]
        for g in band_gaps:
            gc = (g[0] + g[1]) // 2
            # Preskoc pokud uz je blizko konzistentni mezery
            if any(abs(gc - c) < 40 for c in consistent_centers):
                continue
            # Zjisti do ktere bunky pada
            for c1, c2 in zip(col_bounds[:-1], col_bounds[1:]):
                if c1 < gc < c2:
                    # Jen pokud bunka je dostatecne siroka (pravdepodobne 2+ fotek)
                    median_width = np.median([
                        b - a for a, b in zip(col_bounds[:-1], col_bounds[1:])
                        if b - a > 50
                    ]) if len(col_bounds) > 2 else pw
                    if (c2 - c1) > median_width * 1.5:
                        # Over kvalitu mezery v tomto bandu (90%+ bile)
                        strip = bg_mask[y1:y2, g[0]:g[1]+1]
                        if np.mean(strip) > 0.90:
                            col_bounds.append(gc)
                            col_bounds = sorted(set(col_bounds))
                            dbg(f"  Band {bi}: added specific gap at {gc}")
                    break

        # Extrakce fotek z bunek
        for c1, c2 in zip(col_bounds[:-1], col_bounds[1:]):
            if c2 - c1 < 30:
                continue

            cell_gray = gray[y1:y2, c1:c2]
            _, cell_fg = cv2.threshold(
                cell_gray, bg_thresh, 255, cv2.THRESH_BINARY_INV)
            cell_area = cell_gray.shape[0] * cell_gray.shape[1]
            content_pct = cv2.countNonZero(cell_fg) / max(1, cell_area)

            if content_pct < 0.08:
                continue

            coords = cv2.findNonZero(cell_fg)
            if coords is None:
                continue

            fx, fy, fw, fh = cv2.boundingRect(coords)

            # Prevod na originalni souradnice
            orig_x = int((c1 + fx) / scale)
            orig_y = int((y1 + fy) / scale)
            orig_w = int(fw / scale)
            orig_h = int(fh / scale)
            orig_area = orig_w * orig_h

            if min_area <= orig_area <= max_area:
                photos.append((orig_x, orig_y, orig_w, orig_h))
                dbg(f"  Photo: ({orig_x},{orig_y}) {orig_w}x{orig_h} "
                    f"area={orig_area} ({100*orig_area/total_area:.1f}%)")
            else:
                dbg(f"  FILTERED: ({orig_x},{orig_y}) {orig_w}x{orig_h} "
                    f"area={orig_area} not in [{min_area},{max_area}]")

    # ── 7. Fallback: pokud projections nasly malo, zkus threshold+CC ─────
    if len(photos) < 2:
        dbg("Projection method found <2, falling back to threshold+CC")
        photos = detect_threshold_fallback(
            gray, bg_thresh, scale, w, h,
            min_area, max_area, max_count, sensitivity
        )

    # Seradit shora dolu, zleva doprava
    photos.sort(key=lambda p: (p[1], p[0]))
    photos = photos[:max_count]

    dbg(f"Total photos: {len(photos)}")

    results = []
    for (bx, by, bw, bh) in photos:
        results.append({
            "x": bx, "y": by, "w": bw, "h": bh,
            "img_w": w, "img_h": h,
        })

    return results


def detect_threshold_fallback(gray, bg_thresh, scale, orig_w, orig_h,
                               min_area, max_area, max_count, sensitivity):
    """
    Fallback detekce pro obrazky kde projekcni profily selhaly
    (napr. fotky s hodne bilym pozadim nebo jen 1-2 fotky).
    Threshold + eroze + connected components.
    """
    ph, pw = gray.shape

    _, fg = cv2.threshold(gray, bg_thresh, 255, cv2.THRESH_BINARY_INV)

    # Eroze
    erosion_r = int(max(2, round(sensitivity * 12)))
    ek = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE, (2 * erosion_r + 1, 2 * erosion_r + 1))
    eroded = cv2.erode(fg, ek)

    if cv2.countNonZero(eroded) == 0:
        erosion_r = max(1, erosion_r // 2)
        ek = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (2 * erosion_r + 1, 2 * erosion_r + 1))
        eroded = cv2.erode(fg, ek)

    if cv2.countNonZero(eroded) == 0:
        eroded = fg.copy()

    n_labels, labels = cv2.connectedComponents(eroded, connectivity=8)

    boxes = []
    for lbl in range(1, n_labels):
        marker = (labels == lbl).astype(np.uint8) * 255
        if cv2.countNonZero(marker) < 10:
            continue

        mx, my, mw, mh = cv2.boundingRect(marker)
        pad = erosion_r + 5
        rx1 = max(0, mx - pad)
        ry1 = max(0, my - pad)
        rx2 = min(pw, mx + mw + pad)
        ry2 = min(ph, my + mh + pad)

        region_fg = fg[ry1:ry2, rx1:rx2]
        region_marker = marker[ry1:ry2, rx1:rx2]

        dk = erosion_r * 2 + 3
        dilate_k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dk, dk))
        expanded = cv2.dilate(region_marker, dilate_k, iterations=3)
        photo_region = cv2.bitwise_and(expanded, region_fg)

        coords = cv2.findNonZero(photo_region)
        if coords is None:
            continue

        fx, fy, fw, fh = cv2.boundingRect(coords)
        ox = int((rx1 + fx) / scale)
        oy = int((ry1 + fy) / scale)
        ow = int(fw / scale)
        oh = int(fh / scale)
        oa = ow * oh

        if min_area <= oa <= max_area:
            boxes.append((ox, oy, ow, oh))

    return nms_boxes(boxes, overlap_thresh=0.3)


def nms_boxes(boxes, overlap_thresh=0.3):
    """Non-maximum suppression: slouci silne prekryvajici se boxy."""
    if not boxes:
        return boxes

    boxes = sorted(boxes, key=lambda b: b[2] * b[3], reverse=True)
    used = [False] * len(boxes)
    merged = []

    for i in range(len(boxes)):
        if used[i]:
            continue
        x1, y1, w1, h1 = boxes[i]
        changed = True
        while changed:
            changed = False
            for j in range(i + 1, len(boxes)):
                if used[j]:
                    continue
                x2, y2, w2, h2 = boxes[j]
                ix1 = max(x1, x2)
                iy1 = max(y1, y2)
                ix2 = min(x1 + w1, x2 + w2)
                iy2 = min(y1 + h1, y2 + h2)
                if ix2 > ix1 and iy2 > iy1:
                    inter = (ix2 - ix1) * (iy2 - iy1)
                    smaller = min(w1 * h1, w2 * h2)
                    if smaller > 0 and inter / smaller > overlap_thresh:
                        nx = min(x1, x2)
                        ny = min(y1, y2)
                        w1 = max(x1 + w1, x2 + w2) - nx
                        h1 = max(y1 + h1, y2 + h2) - ny
                        x1, y1 = nx, ny
                        used[j] = True
                        changed = True
        merged.append((x1, y1, w1, h1))

    return merged


def main():
    parser = argparse.ArgumentParser(
        description="OpenCV multi-crop photo detection")
    parser.add_argument("image", help="Path to input image")
    parser.add_argument("--sensitivity", type=float, default=0.5,
                        help="Detection sensitivity 0.1-0.9")
    parser.add_argument("--min-area", type=float, default=0.04,
                        help="Min photo area as ratio of total")
    parser.add_argument("--max-area", type=float, default=0.50,
                        help="Max photo area as ratio of total")
    parser.add_argument("--max-count", type=int, default=20,
                        help="Max number of photos to detect")
    parser.add_argument("--debug", action="store_true",
                        help="Print debug info to stderr")

    args = parser.parse_args()

    global DEBUG
    DEBUG = args.debug

    result = detect_photos(
        args.image,
        sensitivity=args.sensitivity,
        min_area_ratio=args.min_area,
        max_area_ratio=args.max_area,
        max_count=args.max_count,
    )

    print(json.dumps(result))


if __name__ == "__main__":
    main()
