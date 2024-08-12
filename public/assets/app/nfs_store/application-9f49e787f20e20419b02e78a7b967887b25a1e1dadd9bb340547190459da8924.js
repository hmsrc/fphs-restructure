var _nfs_store={fs_browser:function(e){"use strict";var t={},a=function(){return $('.container-browser-outer[data-container-id="'+_+'"] .container-browser')},n=function(e,t,a,n){o("download",e,t),o("trash",e,t),o("move-files",e,t),t?(o("rename-file",e,t),o("rename-folder",e,t),r(e,t)):(o("rename-file",e,t=1!=a),r(e,t),o("rename-folder",e,t=1!=n),r(e,t=0==a))},o=function(e,t,a){a||(a=!("true"==w.attr("data-can-submit-"+e)));var n=a?"disabled":null;$("#container-browse-"+e+"-"+_).attr("disabled",n),$("#container-browse-"+e+"-in-form-"+_).attr("disabled",n)},r=function(e,t){$(`[data-target-browser="#container-browser-${_}"][data-can-trigger-actions]`).each((function(){var e=$(this).attr("data-trigger-file-action");if(!t){var a="true"==$(this).attr("data-can-trigger-actions");t=!a}var n=t?"disabled":null;$(this).attr("disabled",n),$(`#container-browse-trigger-file-action-${e}-in-form-${_}`).attr("disabled",n)}))},i=function(e,t){$("#container-browse-download-"+_+" .btn-caption").html(t)},s=function(){var e=$("#container-browse-download-in-form-"+_),t=e.parents("form").first();t.removeAttr("data-remote"),t.removeData("remote"),$("body").addClass("prevent-page-transition"),e.click()},l=function(t,a,n){var o=$("#container-browse-"+a+"-in-form-"+_),r=o.parents("form").first();if(r&&0!==r.length){var i=r.find(".extra_params");if(i.html(""),n)for(var s in n)if(n.hasOwnProperty(s)){var l=n[s];l=l.replace(/"/,"&quot;"),i.append('<input type="hidden" name="nfs_store_download['+s+']" value="'+l+'" />')}r.attr("data-remote","true"),r[0].app_callback=function(){d(e,_)},$("body").addClass("prevent-page-transition"),o.click()}},d=function(e,t){var a=$('.refresh-container-list[data-container-id="'+t+'"]'),n=(new Date).getTime()/1e3,o=a.attr("data-last-click-at");o&&n-parseInt(o)<8?e.find(".browse-container").attr("data-refresh-count","0"):(a.click(),c(e))},c=function(t){e.removeClass("ajax-running"),n(t,!0),u(t)},f=function(e,t,a){t.stopPropagation();var n=w.find('.folder-icon[aria-controls="'+e.attr("id")+'"]');a?(n.removeClass("folder-open"),n.addClass("glyphicon-folder-close"),n.removeClass("glyphicon-folder-open"),n.attr("title","expand folder")):(n.addClass("folder-open"),n.addClass("glyphicon-folder-open"),n.removeClass("glyphicon-folder-close"),n.attr("title","shrink folder"))},p=function(t,a){var n=e.find(".container-browser");if(n.addClass("browser-hide-meta browser-hide-classifications"),t||(t=$('input[name="container-meta-controls-'+_+'"]:checked')),t){var o=t.val();n.removeClass("browser-hide-"+o)}if(!(e.parents(".multi-model-reference-result .is-activity-log").length>0)){var r=e.parents(".common-template-item.is-activity-log").first();if(!r.hasClass("prevent_nfs_resize")){var i=r.hasClass("col-md-8"),s=!1;r.removeClass("col-md-8 col-lg-6 col-lg-8 col-md-12 col-lg-12"),"classifications"==o||"meta"==o?r.addClass("col-md-12 col-lg-12"):(s=!0,r.addClass("col-md-8 col-lg-6")),i!=s&&window.setTimeout((function(){a||_fpa.utils.jump_to_linked_item(r,null,{no_highlight:!0}),_fpa.form_utils.resize_children(e)}),100)}}},u=function(e){var a=w.find('.container-entry input[type="checkbox"]:checked'),o=w.find('.container-folder input[type="checkbox"]:checked'),r=a.length,s=o.length,l=a.first().siblings(".browse-filename").html(),d=a.first().parents(".container-folder-items"),c=d.not('[data-folder-items="."]').last();0!=c.length&&-1!=c.attr("data-folder-items").indexOf("__mounted-archive__")||(c=d.last()),c=c.prev().add(c);var f=d.first();return f=f.prev().add(f),i(e,"download "+r+" "+(1!=r?"files":"file")),n(e,!r,r,s),w.find(".container-entry.checked").removeClass("checked"),a.each((function(){$(this).is(":checked")&&$(this).parent().addClass("checked")})),w.find(".container-folder.checked").removeClass("checked"),o.each((function(){$(this).is(":checked")&&$(this).parent().addClass("checked")})),t={total_checked:r,total_checked_folders:s,first_file:l,$folder_top:c,$folder_in:f}},h=function(e){var t=e.parents(".container-folder-items").first(),a=t.attr("data-folder-items"),n=t.find('> .container-entry input[type="checkbox"]'),o=n.length==n.closest(":checked").length;w.find('.container-folder input[type="checkbox"][data-folder-path="'+a+'"] ').prop("checked",o),u(e)},m=function(e){var t=e.attr("data-folder-path"),a=e.is(":checked");w.find('.container-folder-items[data-folder-items="'+t+'"] li input[type="checkbox"]').prop("checked",a),u(e)},v=function(e){var t=$($(this).attr("data-target-browser")),a={};k.find(".container-browse-action-extra-params").each((function(){var e=$(this);a[e.attr("name")]=e.val()})),l(t,e,a),n(t,!0),k.modal("hide")},g=function(e,t){if(e=e.replace(/^\.?\/?/,"")){if(t)var a=[t,e].join("/");else a=e;a=(a=a.replace(/^\.?\/?/,"")).replace(/^[^\/]+\.__mounted-archive__(\/|$)/,"");k.find('input[name="new_path"]').val(a)}},b=function(){if(e=k.find(".browse-move-to-folders .container-folder.checked [data-folder-path]").first().attr("data-folder-path"))var e=(e=e.replace(/^\.?\/?/,"")).replace(/^[^\/]+\.__mounted-archive__(\/|$)/,"");k.find(".container-browser-move-from").html(e)},_=function(e){var t=e.attr("data-container-id");return t||e.parents(".container-browser-outer").attr("data-container-id")}(e),w=a();e.find("img").on("error",(function(){$(this).addClass("broken-image")})).on("load",(function(){$(this).addClass("loaded-image")})),e.on("change",'.container-browser .container-entry input[type="checkbox"]',(function(){h($(this))})).on("change",'.container-browser .container-folder input[type="checkbox"]',(function(){m($(this))})).on("hidden.bs.collapse",".container-browser .container-folder-items",(function(e){f($(this),e,!0)})).on("shown.bs.collapse",".container-browser .container-folder-items",(function(e){f($(this),e,!1)})).on("click",".container-browse-download",(function(){var e=$($(this).attr("data-target-browser"));s(e),n(e,!0),i(e,"request submitted")})).on("click",".container-browse-trash-submit",(function(){var e=$($(this).attr("data-target-browser"));l(e,"trash"),n(e,!0)})).on("click",".container-browse-trigger-file-action",(function(){var t=$($(this).attr("data-target-browser")),a=$(this).attr("data-trigger-file-action");l(t,"trigger-file-action-"+a),n(t,!0),window.setTimeout((function(){d(e,_)}),1e4)})).on("click",".container-browse-move-files",(function(){$($(this).attr("data-target-browser"));var e=$("#container-browse-move-files-form-"+_).html(),a="Move Files to a folder";_fpa.show_modal(e,a);var n=t.$folder_top,o=(n.find(".container-folder, .container-folder-items"),k.find(".browse-move-to-folders"));n.clone().appendTo(o),n.first().hasClass("root-folder")&&o.find(".container-folder-items").each((function(){var e=$(this);e.attr("data-folder-items").indexOf(".__mounted-archive__")>=0&&(e.prev().remove(),e.remove())})),o.find(".container-entry").remove(),o.find(".container-folder-items").each((function(){var e=$(this),t=e.prev(),a=e.attr("id");e.attr("id","bmtf-"+a),e.attr("aria-expanded","true"),e.addClass("in");var n=e.attr("data-folder-items");$('<a class="container-add"><input type="checkbox" class="container-folder-add hidden" data-folder-path="'+n+'" /> <span class="glyphicon glyphicon-plus"></span> folder</a>').appendTo(t).on("click",(function(e){e.preventDefault(),$(this).find("input.container-folder-add").prop("checked",!0).change();var a=k.find(".container-new-folder-name");a.slideDown(),g(a.val(),n),a.on("keyup",(function(){var e=$(this).val();g(e,n)})),t.append(a)}))})),o.find(".folder-icon").each((function(){var e=$(this),t=e.attr("href");if(t){var a="#bmtf-"+t.replace(/^#/,"");e.attr("href",a),e.attr("aria-controls",a)}e.addClass("folder-open glyphicon-folder-open").removeClass("glyphicon-folder")}));var r=o.find('input[type="checkbox"]');r.each((function(){$(this).prop("checked",!1)})),k.find(".container-new-folder-name").parent().slideUp(),o.on("change",'input[type="checkbox"]',(function(){var e=$(this),t=e.attr("data-folder-path");r.not('[data-folder-path="'+t+'"]').prop("checked",!1);var a=k.find(".container-new-folder-name");e.hasClass("container-folder-add")||a.slideUp(),g(t)})),b()})).on("click",".container-browse-rename-file",(function(){$($(this).attr("data-target-browser"));var e=$("#container-browse-rename-file-form-"+_).html(),a="Rename file";_fpa.show_modal(e,a),k.find('input[name="new_name"]').val(t.first_file)}));var k=$("#primary-modal");k.on("click",".container-browse-move-files-submit",(function(){v("move-files")})).on("click",".container-browse-rename-file-submit",(function(){v("rename-file")})),$(document).on("click",'.refresh-container-list[data-container-id="'+_+'"]',(function(){e.find(".container-browser").addClass("ajax-running");var t=(new Date).getTime()/1e3;$(this).attr("data-last-click-at",t)})).on("change",'input[name="container-meta-controls-'+_+'"]',(function(){p($(this))}));var y=$('input[name="container-meta-controls-'+_+'"]:checked');return p(y,!0),c(e),this},uploader:function(e){"use strict";function t(e,t){if(o)t=null;else{e&&(u=0,a=null,c=e,p=Math.ceil(c.size/f),n=t,l=[]);var r=new FileReader;r.onload=v,r.onerror=g;var i=u*f,s=i+f>=c.size?c.size:i+f;r.readAsArrayBuffer(d.call(c,i,s))}}var a,n,o,r,i,s={url:"/nfs_store/chunk",dataType:"json",autoUpload:!1,dropZone:e.find(".upload-dropzone"),disableImageResize:!0,singleFileUploads:!0,sequentialUploads:!0,previewMaxWidth:100,previewMaxHeight:100,previewCrop:!0,maxChunkSize:1e7,headers:{"X-CSRF-Token":$('meta[name="csrf-token"]').attr("content")}},l=[],d=File.prototype.slice||File.prototype.mozSlice||File.prototype.webkitSlice,c=null,f=s.maxChunkSize,p=0,u=0,h=new SparkMD5.ArrayBuffer,m=new SparkMD5.ArrayBuffer,v=function(e){var o=e.target.result;m.reset(),m.append(o),l.push(m.end()),h.append(o),++u<p?t():(a=h.end(),n&&n(a))},g=function(){!0},b=function(t,a,n,r,i){var s=e.find(".template .file-block").clone(!0).attr("data-file-index",a);s.find(".file-name").text(n.name),o=!1,s.find(".button-upload-abort").on("click",(function(){var e=$(this),t=e.data();e.hide(),o=!0,s.find(".button-upload-resume").show(),t.abort()})).data(t),s.find(".button-upload-resume").on("click",(function(){$(this).hide(),s.find(".button-upload-abort").show(),o=!1,k(s),F(i,r)})),s.find(".started-at").html((new Date).toLocaleTimeString());var l=e.find(".data-context");s.appendTo(l),s.data(t);var d=l.get(0).getBoundingClientRect();return!(d.top>=0&&d.top<=.8*$(window).height())&&$.scrollTo(l,0,{offset:.8*-$(window).height()}),s.find(".close").on("click",(function(){s.slideUp()})),s},_=function(e){e.removeClass("process-ready").addClass("process-complete"),e.removeClass("progress-running"),y(e),console.log("completed upload of file")},w=function(e,t){t||(t=S()),e.join||(e=[e]),t.find(".file-error").text("file upload failed: "+e.join(" | ")),t.find(".progress-bar").addClass("progress-bar-failed").removeClass("progress-bar-success"),t.find(".progress-bar-status-text").text("failed"),t.removeClass("progress-running"),y(t),C()},k=function(e){e.addClass("process-ready").removeClass("process-complete"),e.find(".file-error").text(""),e.find(".progress-bar").removeClass("progress-bar-failed").addClass("progress-bar-success"),e.find(".progress-bar-status-text").text("processing")},y=function(e){e.find(".button-upload-abort").hide()},C=function(){e.find(".fileinput-button").show()},x=function(){e.find(".fileinput-button").hide()},D=function(){e.find(".data-context .file-block[data-file-index]").remove()},S=function(){return e.find(".data-context .file-block.process-ready").first()},T=function(){return e.find(".data-context .file-block")},j=function(e){var t=[],a=e.jqXHR.responseJSON;if(a&&a.message)return t.push(a.message),t;var n=e.jqXHR.getResponseHeader("X-Upload-Errors"),o=JSON.parse(n);for(var r in o)o.hasOwnProperty(r)&&t.push(r.replace("_"," ")+" "+o[r].join("; "));return 0==t.length&&t.push("unknown server error"),t},z=function(){e.find(".refresh-container-list").click()},U=function(){var e=R(),t=O(),a={activity_log_id:e.activity_log_id,activity_log_type:e.activity_log_type,container_id:t,do:"done",uploaded_ids:r.join(",")};$.ajax({url:s.url+"/"+t,data:a,type:"PUT",success:function(){console.log("Sent all done message")}})},O=function(){return e.find("#uploader_container_id").val()},R=function(){var t=e.find(".nfs-store-container-block");return{activity_log_id:t.attr("data-activity-log-id"),activity_log_type:t.attr("data-activity-log-type")}},F=function(e,a){var n=S();if(0!=n.length){var r=n.data();o=!1,n.addClass("progress-running"),n.find(".progress-bar-status-text").text("processing"),i=i||T().length.toString()+"--"+Date.now().toString()+"--"+Math.random().toString(),t(r.files[0],(function(t){r.formData||(r.formData={}),r.formData.file_hash=t,r.formData.container_id=O(),r.formData.upload_set=i,r.files[0].relativePath&&""!=r.files[0].relativePath&&(r.formData.relative_path=r.files[0].relativePath),1==l.length&&(r.formData.chunk_hash=l.shift());var n=R();if(r.formData.activity_log_id=n.activity_log_id,r.formData.activity_log_type=n.activity_log_type,e){var o={file_name:r.files[0].name,file_hash:r.formData.file_hash,relative_path:r.formData.relative_path,activity_log_id:n.activity_log_id,activity_log_type:n.activity_log_type};$.getJSON(s.url+"/"+O(),o,(function(t){if("found"==t.result&&!t.completed){var n=t.file_size,o=t.chunk_count;r.uploadedBytes=n;for(var i=0;i<o;i++)r.formData.chunk_hash=l.shift();$.blueimp.fileupload.prototype.options.add.call(e,a,r)}setTimeout((function(){r.submit()}),100)})).fail((function(e){var t=["The upload failed"];e.responseJSON&&e.responseJSON.message&&(t=e.responseJSON.message),w(t)}))}else setTimeout((function(){r.submit()}),100)}))}};e.find(".upload-dropzone").on("dragover",(function(){$(this).addClass("on-drag")})).on("dragleave",(function(){$(this).removeClass("on-drag")})).on("drop",(function(){e.find(".fileinput-button").is(":visible")?(x(),D(),$(this).removeClass("on-drag")):console.log("Upload not enabled!")}));e.find("input.nfs-store-fileupload").fileupload(s).on("click",(function(){D()})).on("fileuploadadd",(function(t,a){if("false"!=e.find(".container-browser").attr("data-container-writable")){x();var n=this;$.each(a.files,(function(e,o){var i=0==S().length;b(a,e,o,t,n);i&&(r=[],setTimeout((function(){F(n,t)}),1e3))}))}else console.log("Upload not enabled!")})).on("fileuploadchunkbeforesend",(function(e,t){t.formData||(t.formData={}),t.formData.chunk_hash=l.shift(),t.formData.upload_set=i,S().find(".progress-bar-status-text").text("uploading")})).on("fileuploadchunksend",(function(){return!o})).on("fileuploadprocessalways",(function(e,t){console.log("fileuploadprocessalways");var a=0,n=t.files[a],o=S();o.find(".progress-bar-status-text").text("uploading"),n.error&&o.find(".file-error").text(n.error)})).on("fileuploadprogress",(function(e,t){var a=S(),n=parseInt(t.loaded/t.total*100,10);a.find(".progress .progress-bar").css("width",n+"%");var o=a.get(0).getBoundingClientRect();!(o.top>=0&&o.top<=.8*$(window).height())&&$.scrollTo(a,0,{offset:.8*-$(window).height()})})).on("fileuploaddone",(function(e,t){console.log("fileuploadaddone");var a=t.result.file,n=S();a.url?(n.find(".progress-bar-status-text").text("completed"),r.push(a.id)):a.error&&n.find(".file-error").text(a.error)})).on("fileuploadfail",(function(e,t){var a;console.log("fileuploadfail"),a=o?["Upload canceled"]:j(t),w(a)})).on("fileuploadalways",(function(e,t){console.log("fileuploadalways");var a=this;$.each(t.files,(function(){var t=S();t.find(".ended-at").text((new Date).toLocaleTimeString()),_(t);var n=S();!o&&n.length>0?F(a,e):(C(),z(),U())}))})).prop("disabled",!$.support.fileInput).parent().addClass($.support.fileInput?void 0:"disabled")}};