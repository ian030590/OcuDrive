# OcuDrive design direction

Direction source: the requested RehabTrainerHub project, specifically its DESIGN.md and driving-rehab module. This document applies that existing quiet, readable training-tool direction to the desktop simulator.

ENERGY 1 / RHYTHM 1 / MOTION 1. Functional road movement is the exercise stimulus; menus have no decorative motion. The design read is a rehabilitation driving practice tool for participants and supervising practitioners, with a quiet instrument-panel language.

- Background #f6f7f9 and white form surfaces come from the Hub and keep calibration and setup readable in a room with ordinary lighting.
- Text #202428 and secondary #46525b retain contrast for participants with reduced vision.
- Green #146c5b marks the action that advances the training flow. Orange/red appear only as actual traffic or error signals, accompanied by text.
- Microsoft JhengHei UI with system fallback provides Traditional Chinese without downloading a font or loading a large font bundle.
- A single vertical setup form follows the task: participant code, exercise, device, calibration, start. No dashboard or invented statistics.
- Controls have at least 44px height; keyboard focus uses a clearly visible blue border. A scroll container preserves access at smaller desktop sizes.
- The fixed daylight driving view avoids camera shake, expensive shadows and motion effects. Road geometry and traffic symbols are the actual simulation stimuli, not decoration.
- The compact HUD leaves the central road visible. The rear-view schematic avoids a second scene render and is explicitly labeled.
- Only measured results appear after a session; unavailable gaze metrics display as unavailable, never zero.
- Product name remains text. No new brand logo, avatar, testimonial, decorative art or marketing claim is introduced.
- Fixed light setup theme follows the Hub's existing direction and permits reproducible bright calibration targets.
