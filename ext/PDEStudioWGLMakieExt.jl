"""
Browser uploads for the studio served with WGLMakie: *Browse…* opens the browser's file picker and files dropped onto
the window are sent to Julia (`PDEStudio.receive_upload!`), so configurations on the computer in front of you can be
loaded into a studio running on a remote machine.
"""
module PDEStudioWGLMakieExt

using PDEStudio, WGLMakie
using WGLMakie.Bonito: Bonito, Session, @js_str, evaljs

# One upload channel per browser session; weak keys, so closed sessions are dropped with their screens.
const UPLOADS = WeakKeyDict{Session, Observable{Any}}()

_ready(screen::WGLMakie.Screen) = !isnothing(screen.session) && isopen(screen.session) && !isnothing(screen.canvas)

function PDEStudio._connect_browser_upload!(screen::WGLMakie.Screen)
    _ready(screen) || return nothing
    session = screen.session
    haskey(UPLOADS, session) && return nothing
    upload = Observable{Any}(nothing)
    UPLOADS[session] = upload
    on(_handle_message, session, upload)
    evaljs(session, js"""
    (() => {
        const wrapper = $(screen.canvas);
        const upload = $(upload);
        const max_bytes = $(PDEStudio.MAX_UPLOAD_BYTES);

        const send = async (files) => {
            const list = Array.from(files || []);
            if (list.length === 0) { upload.notify({cancelled: true}); return; }
            const big = list.find(f => f.size > max_bytes);
            if (big) {
                upload.notify({error: big.name + " is larger than " + (max_bytes / 1048576) + " MB."});
                return;
            }
            const out = [];
            for (const f of list) { out.push({name: f.name, data: new Uint8Array(await f.arrayBuffer())}); }
            upload.notify({files: out});
        };

        const input = document.createElement("input");
        input.type = "file";
        input.multiple = true;
        input.accept = ".csv,.jl";
        input.style.display = "none";
        input.addEventListener("change", () => { send(input.files); input.value = ""; });
        input.addEventListener("cancel", () => upload.notify({cancelled: true}));
        wrapper.appendChild(input);

        // A browser opens a file picker only right after a click in the page. The click on Browse… usually still
        // counts when this runs; if it doesn't, a small panel asks for one more click.
        const panel = document.createElement("div");
        panel.style.cssText = "position: absolute; left: 50%; top: 40%; transform: translate(-50%, -50%); " +
            "z-index: 10; padding: 14px 18px; background: white; border: 1px solid #999; border-radius: 6px; " +
            "box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25); font-family: sans-serif; font-size: 14px; display: none;";
        panel.textContent = "Load a configuration (CSV or Julia file): ";
        const choose = document.createElement("button");
        choose.textContent = "Choose file…";
        const cancel = document.createElement("button");
        cancel.textContent = "Cancel";
        cancel.style.marginLeft = "6px";
        choose.addEventListener("click", () => { panel.style.display = "none"; input.click(); });
        cancel.addEventListener("click", () => { panel.style.display = "none"; upload.notify({cancelled: true}); });
        panel.append(choose, cancel);
        wrapper.appendChild(panel);

        wrapper.pdestudio_browse = () => {
            if (navigator.userActivation && !navigator.userActivation.isActive) {
                panel.style.display = "block";
            } else {
                input.click();
            }
        };

        const has_files = (e) => e.dataTransfer && Array.from(e.dataTransfer.types || []).includes("Files");
        wrapper.addEventListener("dragover", (e) => {
            if (!has_files(e)) { return; }
            e.preventDefault();
            e.dataTransfer.dropEffect = "copy";
            wrapper.style.outline = "3px dashed #4a90d9";
        });
        wrapper.addEventListener("dragleave", (e) => {
            if (!wrapper.contains(e.relatedTarget)) { wrapper.style.outline = ""; }
        });
        wrapper.addEventListener("drop", (e) => {
            wrapper.style.outline = "";
            if (!has_files(e)) { return; }
            e.preventDefault();
            e.stopPropagation();
            send(e.dataTransfer.files);
        });
        // a file dropped next to the studio would otherwise replace the page (and close the session)
        if (!window.pdestudio_drop_guard) {
            window.pdestudio_drop_guard = true;
            for (const type of ["dragover", "drop"]) {
                window.addEventListener(type, (e) => { if (has_files(e)) { e.preventDefault(); } });
            }
        }
    })();
    """)
    return nothing
end

function PDEStudio._open_upload_picker(screen::WGLMakie.Screen)
    _ready(screen) || return false
    PDEStudio._connect_browser_upload!(screen)   # the session may be newer than the last frame tick
    evaljs(screen.session, js"""$(screen.canvas).pdestudio_browse()""")
    PDEStudio._status!("Choose the file in your browser (a CSV, together with its source files if it has any).", :info)
    return true
end

# Messages of the upload channel: `{files: [{name, data}]}`, `{cancelled: true}` or `{error: text}`.
function _handle_message(msg)
    msg isa AbstractDict || return nothing
    try
        if haskey(msg, "error")
            PDEStudio._report(:warn, "Not uploaded: $(msg["error"])")
        elseif haskey(msg, "files")
            PDEStudio.receive_upload!([String(f["name"]) => Vector{UInt8}(f["data"]) for f in msg["files"]])
        else
            PDEStudio._status!("No file chosen.", :info)
        end
    catch e
        @error "Receiving the uploaded files failed" exception = (e, catch_backtrace())
        PDEStudio._status!("Receiving the uploaded files failed: $(PDEStudio._short(sprint(showerror, e), 80))", :error)
    end
    return nothing
end

end
