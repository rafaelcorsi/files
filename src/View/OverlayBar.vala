/***
    Copyright (C) 2012 ammonkey <am.monkeyd@gmail.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

***/

namespace Marlin.View {

    public class OverlayBar : Granite.Widgets.OverlayBar {
        const int IMAGE_LOADER_BUFFER_SIZE = 8192;
        const int STATUS_UPDATE_DELAY = 200;
        const string[] SKIP_IMAGES = {"image/svg+xml", "image/tiff"};
        Cancellable? cancellable = null;
        bool image_size_loaded = false;
        private uint folders_count = 0;
        private uint files_count = 0;
        private uint64 files_size = 0;
        private GOF.File? goffile = null;
        private GLib.List<unowned GOF.File>? selected_files = null;
        private uint8 [] buffer;
        private GLib.FileInputStream? stream;
        private Gdk.PixbufLoader loader;
        private uint update_timeout_id = 0;
        private Marlin.DeepCount? deep_counter = null;
        private uint deep_count_timeout_id = 0;

        public bool showbar = false;

        public OverlayBar (Marlin.View.Window win, Gtk.Overlay overlay) {
            base (overlay); /* this adds the overlaybar to the overlay (ViewContainer) */

            buffer = new uint8[IMAGE_LOADER_BUFFER_SIZE];
            status = "";

            hide.connect (cancel);
        }

        ~OverlayBar () {
            cancel ();
        }

        public void selection_changed (GLib.List<GOF.File> files) {
            cancel ();
            visible = false;

            if (!showbar)
                return;

            update_timeout_id = GLib.Timeout.add_full (GLib.Priority.LOW, STATUS_UPDATE_DELAY, () => {
                if (files != null)
                    selected_files = files.copy ();
                else
                    selected_files = null;

                real_update (selected_files);
                update_timeout_id = 0;
                return false;
            });
        }

        public void reset_selection () {
            selected_files = null;
        }

        public void update_hovered (GOF.File? file) {
            cancel ();
            visible = false;

            if (!showbar)
                return;

            update_timeout_id = GLib.Timeout.add_full (GLib.Priority.LOW, STATUS_UPDATE_DELAY, () => {
                GLib.List<GOF.File> list = null;
                if (file != null) {
                    bool matched = false;
                    if (selected_files != null) {
                        selected_files.@foreach ((f) => {
                            if (f == file)
                                matched = true;
                        });
                    }

                    if (matched)
                        real_update (selected_files);
                    else {
                        list.prepend (file);
                        real_update (list);
                    }
                } else 
                    real_update (null);

                update_timeout_id = 0;
                return false;
            });
        }

        public void cancel() {
            if (update_timeout_id > 0) {
                GLib.Source.remove (update_timeout_id);
                update_timeout_id = 0;
            }

            if (deep_count_timeout_id > 0) {
                GLib.Source.remove (deep_count_timeout_id);
                deep_count_timeout_id = 0;
            }

            /* if we're still collecting image info or deep counting, cancel */
            if (cancellable != null) {
                cancellable.cancel ();
                cancellable = null;
            }
        }

       private void real_update (GLib.List<GOF.File>? files) {
            goffile = null;
            folders_count = 0;
            files_count = 0;
            files_size = 0;
            status = "";

            if (files != null) {
                if (files.data != null) {
                    if (files.next == null)
                        /* list contain only one element */
                        goffile = files.first ().data;
                    else
                        scan_list (files);

                    status = update_status ();
                }
            }

            visible = showbar && (status.length > 0);
        }

        private string update_status () {
            string str = "";
            if (goffile != null) { /* a single file is hovered or selected */
                if (goffile.is_network_uri_scheme ()) {
                    str = goffile.get_display_target_uri ();
                } else if (!goffile.is_folder ()) {
                    /* if we have an image, see if we can get its resolution */
                    cancellable = new Cancellable ();
                    string? type = goffile.get_ftype ();
                    if (type != null && type.substring (0, 6) == "image/" && !(type in SKIP_IMAGES)) {
                        load_resolution.begin (goffile);
                    }
                    str = "%s- %s (%s)".printf (goffile.info.get_name (),
                                                goffile.formated_type,
                                                format_size (PropertiesWindow.file_real_size (goffile)));
                } else {
                    str = "%s - %s".printf (goffile.info.get_name (), goffile.formated_type);
                    schedule_deep_count ();
                }
            } else { /* hovering over multiple selection */
                if (folders_count > 1) {
                    str = _("%u folders").printf (folders_count);
                    if (files_count > 0)
                        str += ngettext (_(" and %u other item (%s) selected").printf (files_count, format_size (files_size)),
                                         _(" and %u other items (%s) selected").printf (files_count, format_size (files_size)),
                                         files_count);
                    else
                        str += _(" selected");
                } else if (folders_count == 1) {
                    str = _("%u folder").printf (folders_count);
                    if (files_count > 0)
                        str += ngettext (_(" and %u other item (%s) selected").printf (files_count, format_size (files_size)),
                                         _(" and %u other items (%s) selected").printf (files_count, format_size (files_size)),
                                         files_count);
                    else
                        str += _(" selected");
                } else /* folder_count = 0 and files_count > 0 */
                    str = _("%u items selected (%s)").printf (files_count, format_size (files_size));
            }

            return str;
        }

        private void schedule_deep_count () {
            cancel ();
            deep_count_timeout_id = GLib.Timeout.add_full (GLib.Priority.LOW, 1000, () => {
                status += " (counting ...)";
                deep_counter = new Marlin.DeepCount (goffile.location);
                deep_counter.finished.connect (update_status_after_deep_count);

                cancellable = new Cancellable (); /* re-use existing cancellable */
                cancellable.cancelled.connect (() => {
                    if (deep_counter != null) {
                        deep_counter.finished.disconnect (update_status_after_deep_count);
                        deep_counter.cancel ();
                        deep_counter = null;
                    }
                });
                deep_count_timeout_id = 0;
                return false;
            });
        }

        private void update_status_after_deep_count () {
            string str;

            if (deep_counter != null) {
                status = "%s - %s (".printf (goffile.info.get_name (), goffile.formated_type);

                if (deep_counter.dirs_count > 0) {
                    str = ngettext (_("%u sub-folder, "), _("%u sub-folders, "), deep_counter.dirs_count);
                    status += str.printf (deep_counter.dirs_count);
                }

                if (deep_counter.files_count > 0) {
                    str = ngettext (_("%u file, "), _("%u files, "), deep_counter.files_count);
                    status += str.printf (deep_counter.files_count);
                }

                status += format_size (deep_counter.total_size);
                
                if (deep_counter.file_not_read > 0)
                    status += " approx - %u files not readable".printf (deep_counter.file_not_read);

                status += ")";
            }
        }

        private void scan_list (GLib.List<GOF.File>? files) {
            if (files == null)
                return;

            foreach (var gof in files) {
                if (gof.is_folder ()) {
                    folders_count++;
                } else {
                    files_count++;
                    files_size += PropertiesWindow.file_real_size (gof);
                }
            }
        }

        /* code is mostly ported from nautilus' src/nautilus-image-properties.c */
        private async void load_resolution (GOF.File goffile) {
            var file = goffile.location;
            image_size_loaded = false;

            try {
                stream = yield file.read_async (0, cancellable);
                if (stream == null)
                    error ("Could not read image file's size data");
                loader = new Gdk.PixbufLoader.with_mime_type (goffile.get_ftype ());

                loader.size_prepared.connect ((width, height) => {
                    image_size_loaded = true;
                    status = "%s (%s — %i × %i)".printf (goffile.formated_type, goffile.format_size, width, height);
                });

                /* Gdk wants us to always close the loader, so we are nice to it */
                cancellable.cancelled.connect (() => {
                    try {
                        loader.close ();
                        stream.close ();
                    } catch (Error e) {}
                });

                yield read_image_stream (loader, stream, cancellable);
            } catch (Error e) { debug (e.message); }
        }


        private async void read_image_stream (Gdk.PixbufLoader loader, FileInputStream stream, Cancellable cancellable)
        {
            ssize_t read = 1;
            while (!image_size_loaded  && read > 0) {
                try {
                    read = yield stream.read_async (buffer, 0, cancellable);
                    loader.write (buffer);
                    
                } catch (IOError e) {
                    if (!(e is IOError.CANCELLED))
                        warning (e.message);
                } catch (Gdk.PixbufError e) {
                    /* errors while loading are expected, we only need to know the size */
                } catch (FileError e) {
                    warning (e.message);
                } catch (Error e) {
                    warning (e.message);
                }
            }
            cancellable.cancelled ();
        }
    }
}