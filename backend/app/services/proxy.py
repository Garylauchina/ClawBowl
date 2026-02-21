"""Legacy proxy module — kept as empty stub.

Chat traffic now flows directly from the iOS app to the OpenClaw
gateway via nginx (/gw/{port}/).  The thick SSE proxy, attachment
processing, turn detection, and workspace diff logic that was here
has been removed.

Attachment uploads are now handled by the /api/v2/files/upload
endpoint in file_router.py.
"""
