-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter

# GenieX SDK: native libnpu_jni.so resolves Java fields/classes by name via JNI.
# R8 stripping unused enum beans (HubSource, ModelType, ...) broke GetFieldID.
-keep class com.geniex.sdk.** { *; }
-keepclassmembers class com.geniex.sdk.** { *; }
