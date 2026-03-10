#!/usr/bin/env python3
"""
stitch_images.py — Spojení naskenovaných obrázků s překryvem.

Vstup:  cesty k obrázkům jako CLI argumenty + volitelné parametry
Výstup: JSON na stdout {"output": "/path/to/result.jpg", "width": 4000, "height": 3000}
        nebo {"error": "..."}

Vyžaduje: Python 3, OpenCV (cv2), numpy
"""

import sys
import os
import json
import argparse
import traceback

try:
    import cv2
    import numpy as np
except ImportError as e:
    print(json.dumps({"error": f"Chybí knihovna: {e}. Nainstalujte: pip3 install opencv-python numpy"}))
    sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(description="Stitch scanned images with overlap")
    parser.add_argument("images", nargs="+", help="Paths to input images")
    parser.add_argument("--features", default="orb", choices=["orb", "sift", "akaze"],
                        help="Feature detector (default: orb)")
    parser.add_argument("--warp", default="plane", choices=["plane", "spherical", "affine"],
                        help="Warp type (default: plane)")
    parser.add_argument("--blend", default="multiband", choices=["multiband", "feather", "no"],
                        help="Blend type (default: multiband)")
    parser.add_argument("--work-megapix", type=float, default=0.6,
                        help="Resolution for processing in megapixels (default: 0.6)")
    parser.add_argument("--confidence", type=float, default=0.8,
                        help="Confidence threshold for matching (default: 0.8)")
    parser.add_argument("--output", default=None,
                        help="Output file path (default: auto-generated)")
    return parser.parse_args()


def create_feature_finder(features_type):
    """Create feature finder based on type."""
    if features_type == "orb":
        return cv2.ORB_create()
    elif features_type == "sift":
        return cv2.SIFT_create()
    elif features_type == "akaze":
        return cv2.AKAZE_create()
    else:
        return cv2.ORB_create()


def get_warp_type(warp_name):
    """Map warp name to OpenCV constant."""
    mapping = {
        "plane": cv2.detail.WARP_PLANE if hasattr(cv2.detail, 'WARP_PLANE') else 0,
        "spherical": cv2.detail.WARP_SPHERICAL if hasattr(cv2.detail, 'WARP_SPHERICAL') else 1,
        "affine": cv2.detail.WARP_AFFINE if hasattr(cv2.detail, 'WARP_AFFINE') else 3,
    }
    return mapping.get(warp_name, 0)


def stitch_simple(images, args):
    """Try simple OpenCV Stitcher first — works well for most scan cases."""
    mode = cv2.Stitcher_SCANS
    stitcher = cv2.Stitcher_create(mode)

    # Configure stitcher
    if args.confidence != 0.8:
        try:
            stitcher.setPanoConfidenceThresh(args.confidence)
        except AttributeError:
            pass

    status, result = stitcher.stitch(images)

    if status == cv2.Stitcher_OK:
        return result
    elif status == cv2.Stitcher_ERR_NEED_MORE_IMGS:
        return None  # Fall through to detailed pipeline
    elif status == cv2.Stitcher_ERR_HOMOGRAPHY_EST_FAIL:
        return None
    elif status == cv2.Stitcher_ERR_CAMERA_PARAMS_ADJUST_FAIL:
        return None
    else:
        return None


def stitch_detailed(images, args):
    """Detailed stitching pipeline for harder cases."""
    work_megapix = args.work_megapix
    finder = create_feature_finder(args.features)

    # Resize images for feature detection
    work_images = []
    work_scales = []
    for img in images:
        h, w = img.shape[:2]
        mpx = h * w / 1e6
        if mpx > work_megapix:
            scale = (work_megapix / mpx) ** 0.5
        else:
            scale = 1.0
        work_scales.append(scale)
        if scale < 1.0:
            work_img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        else:
            work_img = img
        work_images.append(work_img)

    # Find features
    features_list = []
    for work_img in work_images:
        gray = cv2.cvtColor(work_img, cv2.COLOR_BGR2GRAY)
        kps, descs = finder.detectAndCompute(gray, None)
        if descs is None:
            raise ValueError("Nelze najít features v jednom z obrázků. Zkuste jiný detektor.")
        features_list.append((kps, descs))

    # Match features between consecutive pairs
    if args.features == "orb":
        matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=False)
    else:
        matcher = cv2.BFMatcher(cv2.NORM_L2, crossCheck=False)

    # Find homographies between consecutive images
    homographies = [np.eye(3, dtype=np.float64)]  # first image = identity
    for i in range(len(images) - 1):
        kps1, descs1 = features_list[i]
        kps2, descs2 = features_list[i + 1]

        raw_matches = matcher.knnMatch(descs1, descs2, k=2)

        # Lowe's ratio test
        good = []
        for m_pair in raw_matches:
            if len(m_pair) == 2:
                m, n = m_pair
                if m.distance < 0.75 * n.distance:
                    good.append(m)

        if len(good) < 10:
            raise ValueError(
                f"Nedostatek shod mezi obrázky {i + 1} a {i + 2} "
                f"({len(good)} shod, potřeba ≥ 10). "
                f"Zkontrolujte, zda obrázky mají dostatečný překryv."
            )

        src_pts = np.float32([kps1[m.queryIdx].pt for m in good]).reshape(-1, 1, 2)
        dst_pts = np.float32([kps2[m.trainIdx].pt for m in good]).reshape(-1, 1, 2)

        # Scale points back to original resolution
        s1 = work_scales[i]
        s2 = work_scales[i + 1]
        src_pts /= s1
        dst_pts /= s2

        H, mask = cv2.findHomography(dst_pts, src_pts, cv2.RANSAC, 5.0)
        if H is None:
            raise ValueError(f"Homografie selhala pro obrázky {i + 1} a {i + 2}.")

        # Chain homographies: H_i = H_{i-1} @ H_local
        homographies.append(homographies[-1] @ H)

    # Compute output canvas size
    corners = []
    for i, img in enumerate(images):
        h, w = img.shape[:2]
        pts = np.float32([[0, 0], [w, 0], [w, h], [0, h]]).reshape(-1, 1, 2)
        warped_pts = cv2.perspectiveTransform(pts, homographies[i])
        corners.append(warped_pts)

    all_corners = np.concatenate(corners, axis=0)
    x_min = int(np.floor(all_corners[:, 0, 0].min()))
    y_min = int(np.floor(all_corners[:, 0, 1].min()))
    x_max = int(np.ceil(all_corners[:, 0, 0].max()))
    y_max = int(np.ceil(all_corners[:, 0, 1].max()))

    # Limit canvas size to avoid OOM
    canvas_w = x_max - x_min
    canvas_h = y_max - y_min
    max_dim = 30000
    if canvas_w > max_dim or canvas_h > max_dim:
        raise ValueError(
            f"Výsledný obrázek by byl příliš velký ({canvas_w}x{canvas_h}). "
            f"Zkontrolujte vstupní obrázky."
        )

    # Translation to move everything to positive coordinates
    translation = np.array([[1, 0, -x_min],
                            [0, 1, -y_min],
                            [0, 0, 1]], dtype=np.float64)

    # Warp and blend
    if args.blend == "no":
        result = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)
        for i, img in enumerate(images):
            H = translation @ homographies[i]
            warped = cv2.warpPerspective(img, H, (canvas_w, canvas_h))
            mask = (warped > 0).any(axis=2)
            result[mask] = warped[mask]
    elif args.blend == "feather":
        result = np.zeros((canvas_h, canvas_w, 3), dtype=np.float64)
        weight_sum = np.zeros((canvas_h, canvas_w), dtype=np.float64)
        for i, img in enumerate(images):
            H = translation @ homographies[i]
            warped = cv2.warpPerspective(img, H, (canvas_w, canvas_h))
            mask = (warped > 0).any(axis=2).astype(np.float64)
            # Distance transform for feather blending
            dist = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
            dist = np.clip(dist, 0, 50) / 50.0  # normalize
            for c in range(3):
                result[:, :, c] += warped[:, :, c].astype(np.float64) * dist
            weight_sum += dist
        weight_sum = np.maximum(weight_sum, 1e-6)
        for c in range(3):
            result[:, :, c] /= weight_sum
        result = np.clip(result, 0, 255).astype(np.uint8)
    else:
        # Multiband blending (default) — use simple weighted blend
        result = np.zeros((canvas_h, canvas_w, 3), dtype=np.float64)
        weight_sum = np.zeros((canvas_h, canvas_w), dtype=np.float64)
        for i, img in enumerate(images):
            H = translation @ homographies[i]
            warped = cv2.warpPerspective(img, H, (canvas_w, canvas_h))
            mask = (warped > 0).any(axis=2).astype(np.uint8)
            dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
            for c in range(3):
                result[:, :, c] += warped[:, :, c].astype(np.float64) * dist
            weight_sum += dist
        weight_sum = np.maximum(weight_sum, 1e-6)
        for c in range(3):
            result[:, :, c] /= weight_sum
        result = np.clip(result, 0, 255).astype(np.uint8)

    # Crop black borders
    gray = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
    _, thresh = cv2.threshold(gray, 1, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if contours:
        all_pts = np.concatenate(contours)
        x, y, w, h = cv2.boundingRect(all_pts)
        # Add small margin
        margin = 2
        x = max(0, x - margin)
        y = max(0, y - margin)
        w = min(result.shape[1] - x, w + 2 * margin)
        h = min(result.shape[0] - y, h + 2 * margin)
        result = result[y:y+h, x:x+w]

    return result


def main():
    args = parse_args()

    # Validate input images
    images = []
    for path in args.images:
        if not os.path.exists(path):
            print(json.dumps({"error": f"Soubor neexistuje: {path}"}))
            sys.exit(1)
        img = cv2.imread(path)
        if img is None:
            print(json.dumps({"error": f"Nelze načíst obrázek: {path}"}))
            sys.exit(1)
        images.append(img)

    if len(images) < 2:
        print(json.dumps({"error": "Potřeba alespoň 2 obrázky pro spojení."}))
        sys.exit(1)

    # Determine output path
    if args.output:
        output_path = args.output
    else:
        base = os.path.splitext(args.images[0])[0]
        ext = os.path.splitext(args.images[0])[1] or ".jpg"
        output_path = f"{base}_stitched{ext}"

    # Try simple stitcher first
    result = stitch_simple(images, args)

    # If simple fails, try detailed pipeline
    if result is None:
        result = stitch_detailed(images, args)

    if result is None:
        print(json.dumps({"error": "Spojení selhalo. Obrázky nemají dostatečný překryv nebo kvalitu."}))
        sys.exit(1)

    # Save result
    ext = os.path.splitext(output_path)[1].lower()
    if ext in (".jpg", ".jpeg"):
        cv2.imwrite(output_path, result, [cv2.IMWRITE_JPEG_QUALITY, 95])
    elif ext == ".png":
        cv2.imwrite(output_path, result)
    elif ext in (".tif", ".tiff"):
        cv2.imwrite(output_path, result)
    else:
        cv2.imwrite(output_path, result, [cv2.IMWRITE_JPEG_QUALITY, 95])

    h, w = result.shape[:2]
    print(json.dumps({"output": output_path, "width": w, "height": h}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
