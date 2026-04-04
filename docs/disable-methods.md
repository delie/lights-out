# LightsOut - Disable Methods

## Default Disable Method

**How to Use?**

Just click on any monitor with an "Active" state.

**How It Works?**

This method leverages a private macOS API to completely stop communication between the monitor and the Mac. It ensures the monitor is entirely disabled without impacting system performance or window arrangements. This lowers GPU usage and is very stable.

## Mirroring Disable Method

**How to Use?**

Click on a monitor with an "Active" state while holding the Shift key.

**How It Works?**

The monitor switches to mirror another display (this ensures the windows there are moved to that display), and its gamma settings are adjusted to zero (to darken the monitor). The main advantage of this method is that macOS is not aware that the monitor is "off" — which may be helpful to some users. **You should only use this if the default method does not work for your use case.**

> **Note:** The mirroring-based disable method may provide nondeterministic results or be re-enabled semi-randomly. For example, turning off a different monitor will sometimes re-enable a monitor disabled with the mirroring-based method. I'll try to handle some of these issues in upcoming updates.
