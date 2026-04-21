#!/usr/bin/env python3
"""
Verifier for UTM Coordinate Navigation task.

VERIFICATION STRATEGY (Multi-Signal, Anti-Gaming):
1. Status-bar VLM: UTM format visible on-screen (30 points)
2. Config modification timestamp (10 points) - anti-gaming
3. Trajectory VLM: Shows preferences dialog interaction (10 points)
4. View location check: Near Devils Tower (25 points)
5. Final VLM: Devils Tower visible (15 points)
6. Final VLM: UTM coordinates displayed (10 points)

Total: 100 points
Pass threshold: 70 points with UTM visible (mandatory)

Note on criterion 1: GE Pro on Linux does not persist the coordinate-format
preference to ~/.config/Google/GoogleEarthPro.conf via any documented key
(pre-seeded candidates LatLonDisplayFormat/coordFormat/CoordinateFormat/
LatLonFormat are all stripped on GE's first read). The setting only exists
in the running UI, so we verify it by VLM-reading the status-bar strip of
the final screenshot. The same VLM call also extracts the UTM zone/easting/
northing; criterion 4 (view location) converts those to WGS84 via the
`utm` package and haversines against the target. The old source —
`grep -oE '<latitude>' myplaces.kml | tail -1` in export_result.sh — was
always reading the last placemark of the default "Sightseeing" folder
(Google HQ), giving a constant 1656.5 km regardless of the agent's view.

Uses copy_from_env (NOT exec_in_env) and trajectory frames for VLM.
"""

import json
import tempfile
import os
import logging
from math import radians, sin, cos, sqrt, atan2

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def haversine_distance(lat1, lon1, lat2, lon2):
    """Calculate distance in km between two coordinate points."""
    R = 6371  # Earth's radius in km
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat/2)**2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon/2)**2
    c = 2 * atan2(sqrt(a), sqrt(1-a))
    return R * c


# =============================================================================
# VLM PROMPTS
# =============================================================================

TRAJECTORY_PROCESS_PROMPT = """You are analyzing a sequence of screenshots from an agent configuring coordinate settings in Google Earth Pro.

The images are sampled chronologically from the agent's interaction (earliest to latest).

For this task, the agent should:
1. Open the Options/Preferences dialog (Tools menu → Options)
2. Navigate to the "3D View" tab in preferences
3. Change coordinate display format to UTM (Universal Transverse Mercator)
4. Apply and close the dialog
5. Navigate to a location using UTM coordinates

Assess these criteria based on what you see across ALL frames:

1. PREFERENCES_DIALOG_VISIBLE: At any point, is a preferences/options dialog window visible?
   (Look for a dialog with tabs like "3D View", settings panels, Apply/OK buttons)

2. COORDINATE_SETTINGS_SHOWN: Is there a dropdown or setting related to coordinate format?
   (Look for "Show Lat/Long", "Decimal Degrees", "UTM" options)

3. UTM_OPTION_SELECTED: Is "Universal Transverse Mercator" or "UTM" visible as selected?

4. MEANINGFUL_PROGRESSION: Do the frames show real state changes (preferences opening, 
   settings being changed, navigation occurring)?

Respond in JSON format:
{
    "preferences_dialog_visible": true/false,
    "coordinate_settings_shown": true/false,
    "utm_option_selected": true/false,
    "meaningful_progression": true/false,
    "stages_observed": ["list what you see happening"],
    "confidence": "low"/"medium"/"high",
    "observations": "describe what you observe across frames"
}
"""


FINAL_VIEW_PROMPT = """You are verifying if Google Earth Pro is showing Devils Tower National Monument.

Devils Tower is a distinctive geological formation in Wyoming, USA:
- A tall, columnar rock tower with vertical striations/ridges
- Rises dramatically from relatively flat surrounding terrain
- Located in northeastern Wyoming
- The top is flat, the sides have distinctive vertical grooves
- Surrounded by forest and prairie

Also check for UTM coordinate display:
- UTM coordinates appear in the status bar at the bottom
- Format shows zone (like "13T" or "13N") followed by numbers
- Example: "13T 534350mE 4940750mN" or similar
- This is DIFFERENT from regular lat/long like "44.59°N, 104.71°W"

Analyze this screenshot:

1. IS_GOOGLE_EARTH: Is this Google Earth (satellite/aerial imagery interface)?

2. DEVILS_TOWER_VISIBLE: Is Devils Tower visible? Look for:
   - The distinctive columnar rock formation
   - Vertical striations on the rock face
   - The tower rising from flat/forested terrain
   - Could be close-up (showing rock detail) or wider view (showing tower in landscape)

3. UTM_COORDINATES_DISPLAYED: Are UTM coordinates visible in the status bar?
   Look for format like "13T" or "13N" followed by Easting/Northing values
   NOT regular decimal degrees or degrees-minutes-seconds

4. WYOMING_AREA: Does this look like Wyoming terrain (prairie, badlands, sparse vegetation)?

Respond in JSON format:
{
    "is_google_earth": true/false,
    "devils_tower_visible": true/false,
    "utm_coordinates_displayed": true/false,
    "wyoming_area": true/false,
    "confidence": "low"/"medium"/"high",
    "reasoning": "describe what you see"
}
"""


# =============================================================================
# MAIN VERIFICATION FUNCTION
# =============================================================================

def verify_utm_coordinate_navigation(traj, env_info, task_info):
    """
    Verify UTM coordinate navigation task completion.
    
    Multi-criteria scoring with anti-gaming measures.
    Uses copy_from_env and trajectory-based VLM verification.
    """
    # Get required functions
    copy_from_env = env_info.get('copy_from_env')
    query_vlm = env_info.get('query_vlm')
    
    if not copy_from_env:
        return {
            "passed": False,
            "score": 0,
            "feedback": "❌ Copy function not available for verification"
        }
    
    # Get metadata
    metadata = task_info.get('metadata', {})
    target = metadata.get('target_location', {})
    target_lat = target.get('lat', 44.5902)
    target_lon = target.get('lon', -104.7146)
    tolerance_km = target.get('tolerance_km', 5.0)
    
    feedback_parts = []
    score = 0
    details = {}
    
    # ================================================================
    # STEP 1: Copy and parse result file from container
    # ================================================================
    result_data = None
    temp_result = tempfile.NamedTemporaryFile(delete=False, suffix='.json')
    try:
        copy_from_env("/tmp/task_result.json", temp_result.name)
        with open(temp_result.name, 'r') as f:
            result_data = json.load(f)
        details['result_file_loaded'] = True
    except Exception as e:
        logger.warning(f"Could not load result file: {e}")
        details['result_file_loaded'] = False
        details['result_file_error'] = str(e)
    finally:
        if os.path.exists(temp_result.name):
            os.unlink(temp_result.name)
    
    # ================================================================
    # CRITERION 1: UTM format visible in status bar (30 points)
    # Reads the UI directly instead of the config file — see module docstring.
    # ================================================================
    utm_enabled = False
    if query_vlm:
        temp_screenshot = tempfile.NamedTemporaryFile(delete=False, suffix='.png')
        temp_strip = tempfile.NamedTemporaryFile(delete=False, suffix='.png')
        try:
            copy_from_env("/tmp/task_final_state.png", temp_screenshot.name)
            if os.path.getsize(temp_screenshot.name) > 1000:
                # Crop the bottom-right status-bar strip where GE prints coords.
                from PIL import Image
                img = Image.open(temp_screenshot.name)
                w, h = img.size
                strip = img.crop((w // 2, h - 60, w, h))
                # Upscale so small text is legible to the VLM.
                strip = strip.resize(
                    (strip.size[0] * 2, strip.size[1] * 3), Image.LANCZOS
                )
                strip.save(temp_strip.name)

                vlm_result = query_vlm(
                    prompt=(
                        "You are looking at the bottom-right status bar of "
                        "Google Earth Pro. UTM-style coordinates look like "
                        "'13 T 522598.36 m E 4937506.82 m N'. Decimal/DMS "
                        "coordinates look like "
                        "\"25°00'00.62\\\" N 39°59'59.67\\\" W\". "
                        "Respond with a single JSON object on one line, no "
                        "prose, no code fence. Schema: "
                        '{"utm_displayed": <bool>, '
                        '"zone_number": <int 1-60 or null>, '
                        '"zone_letter": <single uppercase letter C-X or null>, '
                        '"easting": <float meters or null>, '
                        '"northing": <float meters or null>}. '
                        "If coordinates are not UTM or unreadable, set "
                        "utm_displayed=false and all others to null."
                    ),
                    image=temp_strip.name,
                )

                if vlm_result.get('success'):
                    parsed = vlm_result.get('parsed') or {}
                    utm_enabled = bool(parsed.get('utm_displayed'))
                    details['utm_status_bar'] = {
                        'response': (vlm_result.get('response') or '')[:200],
                        'visible': utm_enabled,
                        'zone_number': parsed.get('zone_number'),
                        'zone_letter': parsed.get('zone_letter'),
                        'easting': parsed.get('easting'),
                        'northing': parsed.get('northing'),
                    }
                    if utm_enabled:
                        score += 30
                        feedback_parts.append(
                            "✅ UTM format visible in status bar (30pts)"
                        )
                        # Convert UTM → WGS84 lat/lon for the view-location
                        # criterion below. Cache on `details` so Criterion 3
                        # can read it without another VLM call.
                        try:
                            import utm as _utm
                            zn = parsed.get('zone_number')
                            zl = parsed.get('zone_letter')
                            ea = parsed.get('easting')
                            no = parsed.get('northing')
                            if (zn is not None and zl and ea is not None
                                    and no is not None):
                                lat, lon = _utm.to_latlon(
                                    float(ea), float(no), int(zn), zl
                                )
                                details['view_latlon_from_vlm'] = {
                                    'lat': float(lat), 'lon': float(lon),
                                }
                        except Exception as e:
                            logger.warning(
                                f"UTM→lat/lon conversion failed: {e}"
                            )
                    else:
                        feedback_parts.append(
                            "❌ UTM format not visible in status bar"
                        )
                else:
                    details['utm_status_bar_error'] = vlm_result.get('error', '')
                    feedback_parts.append("⚠️ UTM status-bar VLM query failed")
            else:
                feedback_parts.append("❌ Final screenshot too small/empty")
        except Exception as e:
            logger.warning(f"UTM status-bar check error: {e}")
            feedback_parts.append(f"⚠️ UTM status-bar check error: {e}")
        finally:
            for f in (temp_screenshot.name, temp_strip.name):
                if os.path.exists(f):
                    os.unlink(f)
    else:
        feedback_parts.append("❌ VLM unavailable for UTM status-bar check")
    
    # ================================================================
    # CRITERION 2: Config modified during task (10 points) - Anti-gaming
    # ================================================================
    config_modified = False
    if result_data:
        config_checks = result_data.get('config_checks', {})
        config_modified = config_checks.get('config_modified_during_task', False)
        
        details['config_modified'] = config_modified
        
        if config_modified:
            score += 10
            feedback_parts.append("✅ Config modified during task (10pts)")
        elif utm_enabled:
            # UTM was enabled but not during this task - suspicious
            score += 3
            feedback_parts.append("⚠️ Config not modified during task (3pts)")
        else:
            feedback_parts.append("❌ Config not modified")
    
    # ================================================================
    # CRITERION 3: View location check (25 points)
    # Uses the lat/lon derived in Criterion 1 from the status-bar UTM
    # coordinates (converted via the `utm` package). The previous
    # source — `grep -oE '<latitude>' myplaces.kml | tail -1` in
    # export_result.sh — never reflected the GE view and always read
    # the last placemark in the default "Sightseeing" folder
    # (Google HQ, ~1656 km from Devils Tower) regardless of where the
    # agent actually navigated.
    # ================================================================
    view_near_target = False
    view_latlon = details.get('view_latlon_from_vlm') or {}
    view_lat = view_latlon.get('lat')
    view_lon = view_latlon.get('lon')

    if view_lat is not None and view_lon is not None:
        distance = haversine_distance(
            target_lat, target_lon, view_lat, view_lon
        )
        details['view_distance_km'] = distance

        if distance <= tolerance_km:
            view_near_target = True
            score += 25
            feedback_parts.append(
                f"✅ View near Devils Tower ({distance:.1f}km away) (25pts)"
            )
        elif distance <= tolerance_km * 2:
            score += 15
            feedback_parts.append(
                f"⚠️ View somewhat near target ({distance:.1f}km away) (15pts)"
            )
        else:
            feedback_parts.append(
                f"❌ View far from target ({distance:.1f}km away)"
            )
    else:
        details['view_distance_km'] = None
        if utm_enabled:
            feedback_parts.append(
                "⚠️ UTM visible but coords not parseable — cannot score view"
            )
        else:
            feedback_parts.append(
                "❌ No UTM coordinates to derive view location from"
            )
    
    # ================================================================
    # CRITERION 4-5: VLM Trajectory Verification (10 points)
    # ================================================================
    trajectory_score = 0
    if query_vlm and traj:
        # Import trajectory frame sampling
        try:
            from gym_anything.vlm import sample_trajectory_frames
            frames = sample_trajectory_frames(traj, num_samples=5)
            
            if frames and len(frames) > 0:
                vlm_result = query_vlm(
                    prompt=TRAJECTORY_PROCESS_PROMPT,
                    images=frames
                )
                
                if vlm_result.get('success'):
                    parsed = vlm_result.get('parsed', {})
                    details['trajectory_vlm'] = parsed
                    
                    prefs_visible = parsed.get('preferences_dialog_visible', False)
                    coord_settings = parsed.get('coordinate_settings_shown', False)
                    utm_selected = parsed.get('utm_option_selected', False)
                    progression = parsed.get('meaningful_progression', False)
                    
                    if prefs_visible:
                        trajectory_score += 4
                    if coord_settings or utm_selected:
                        trajectory_score += 4
                    if progression:
                        trajectory_score += 2
                    
                    score += trajectory_score
                    
                    if trajectory_score >= 8:
                        feedback_parts.append(f"✅ Trajectory shows preferences interaction ({trajectory_score}pts)")
                    elif trajectory_score > 0:
                        feedback_parts.append(f"⚠️ Partial trajectory evidence ({trajectory_score}pts)")
                    else:
                        feedback_parts.append("❌ No preferences interaction in trajectory")
                else:
                    details['trajectory_vlm_error'] = vlm_result.get('error', 'Unknown')
                    feedback_parts.append("⚠️ Trajectory VLM query failed")
            else:
                feedback_parts.append("⚠️ No trajectory frames available")
        except ImportError:
            feedback_parts.append("⚠️ Trajectory frame sampling not available")
    else:
        feedback_parts.append("⚠️ VLM or trajectory not available")
    
    # ================================================================
    # CRITERION 6-7: Final Screenshot VLM (25 points total)
    # ================================================================
    final_vlm_score = 0
    if query_vlm:
        # Copy final screenshot
        temp_screenshot = tempfile.NamedTemporaryFile(delete=False, suffix='.png')
        try:
            copy_from_env("/tmp/task_final_state.png", temp_screenshot.name)
            
            # Check file size
            if os.path.getsize(temp_screenshot.name) > 1000:
                vlm_result = query_vlm(
                    prompt=FINAL_VIEW_PROMPT,
                    image=temp_screenshot.name
                )
                
                if vlm_result.get('success'):
                    parsed = vlm_result.get('parsed', {})
                    details['final_vlm'] = parsed
                    
                    is_ge = parsed.get('is_google_earth', False)
                    devils_tower = parsed.get('devils_tower_visible', False)
                    utm_displayed = parsed.get('utm_coordinates_displayed', False)
                    wyoming = parsed.get('wyoming_area', False)
                    confidence = parsed.get('confidence', 'low')
                    
                    # Devils Tower visible (15 points)
                    if devils_tower:
                        if confidence == 'high':
                            final_vlm_score += 15
                        elif confidence == 'medium':
                            final_vlm_score += 12
                        else:
                            final_vlm_score += 8
                        feedback_parts.append(f"✅ Devils Tower visible ({confidence} conf)")
                    elif wyoming and is_ge:
                        final_vlm_score += 5
                        feedback_parts.append("⚠️ Wyoming area visible but Devils Tower unclear")
                    else:
                        feedback_parts.append("❌ Devils Tower not visible")
                    
                    # UTM coordinates displayed (10 points)
                    if utm_displayed:
                        final_vlm_score += 10
                        feedback_parts.append("✅ UTM coordinates displayed in status bar")
                    else:
                        feedback_parts.append("❌ UTM coordinates not visible in status bar")
                    
                    score += final_vlm_score
                else:
                    details['final_vlm_error'] = vlm_result.get('error', 'Unknown')
                    feedback_parts.append("⚠️ Final VLM query failed")
            else:
                feedback_parts.append("⚠️ Final screenshot too small or empty")
        except Exception as e:
            logger.warning(f"Could not process final screenshot: {e}")
            feedback_parts.append(f"⚠️ Could not load final screenshot: {str(e)}")
        finally:
            if os.path.exists(temp_screenshot.name):
                os.unlink(temp_screenshot.name)
    
    # ================================================================
    # FINAL SCORING
    # ================================================================
    details['score_breakdown'] = {
        'utm_status_bar': 30 if utm_enabled else 0,
        'config_modified': 10 if config_modified else (3 if utm_enabled else 0),
        'view_location': 25 if view_near_target else 0,
        'trajectory_vlm': trajectory_score,
        'final_vlm': final_vlm_score
    }
    
    # Pass criteria:
    # - Must have UTM enabled (mandatory)
    # - Score >= 70
    passed = utm_enabled and score >= 70
    
    # Build final feedback
    feedback = " | ".join(feedback_parts)
    feedback += f" | Total: {score}/100"
    
    if passed:
        feedback = f"✅ PASSED - {feedback}"
    else:
        if not utm_enabled:
            feedback = f"❌ FAILED (UTM not visible in status bar - mandatory) - {feedback}"
        else:
            feedback = f"❌ FAILED (score {score} < 70) - {feedback}"
    
    return {
        "passed": passed,
        "score": score,
        "feedback": feedback,
        "details": details
    }