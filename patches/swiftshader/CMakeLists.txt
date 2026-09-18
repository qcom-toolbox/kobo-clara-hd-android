# Standalone NDK build of SwiftShader's (2019) OpenGL ES + EGL for the
# KitKat Android EGL loader: libEGL_swiftshader.so,
# libGLESv1_CM_swiftshader.so, libGLESv2_swiftshader.so.
# Mirrors src/**/Android.mk at the pinned commit, with Subzero as the JIT
# (the upstream choice for android_arm) and PLATFORM_SDK_VERSION=19.
cmake_minimum_required(VERSION 3.10)
project(swiftshader_kk C CXX ASM)

set(SS ${CMAKE_CURRENT_SOURCE_DIR}/../ss2019)
set(KK ${CMAKE_CURRENT_SOURCE_DIR}/../kitkat)
set(SRC ${SS}/src)
set(SZ ${SS}/third_party/subzero)
set(LLS ${SS}/third_party/llvm-subzero)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_compile_options(
  -DANDROID_PLATFORM_SDK_VERSION=19
  -D__STDC_CONSTANT_MACROS -D__STDC_LIMIT_MACROS
  -DNO_SANITIZE_FUNCTION=
  -DALLOW_DUMP=0 -DALLOW_TIMERS=0 -DALLOW_LLVM_CL=0 -DALLOW_LLVM_IR=0
  -DALLOW_LLVM_IR_AS_INPUT=0 -DALLOW_MINIMAL_BUILD=0 -DALLOW_WASM=0
  -DICE_THREAD_LOCAL_HACK=1 -DSZTARGET=ARM32
  -DANGLE_DISABLE_TRACE -DNDEBUG -U_FORTIFY_SOURCE -DHAVE_SYS_UIO_H
  -fno-operator-names -ffunction-sections -fdata-sections -O2
  -Wno-everything)

set(KK_INCLUDES
  ${KK}/system_core ${KK}/libhardware)
set(SUBZERO_INCLUDES
  ${SZ} ${LLS}/include ${LLS}/build/Android/include ${SZ}/pnacl-llvm/include)

# ---- libsubzero (JIT + minimal LLVM Support) ----
set(SUBZERO_SRCS
  ${LLS}/lib/Support/APInt.cpp
  ${LLS}/lib/Support/Atomic.cpp
  ${LLS}/lib/Support/circular_raw_ostream.cpp
  ${LLS}/lib/Support/CommandLine.cpp
  ${LLS}/lib/Support/ConvertUTF.cpp
  ${LLS}/lib/Support/ConvertUTFWrapper.cpp
  ${LLS}/lib/Support/Debug.cpp
  ${LLS}/lib/Support/ErrorHandling.cpp
  ${LLS}/lib/Support/FoldingSet.cpp
  ${LLS}/lib/Support/Hashing.cpp
  ${LLS}/lib/Support/Host.cpp
  ${LLS}/lib/Support/ManagedStatic.cpp
  ${LLS}/lib/Support/MemoryBuffer.cpp
  ${LLS}/lib/Support/Mutex.cpp
  ${LLS}/lib/Support/NativeFormatting.cpp
  ${LLS}/lib/Support/Path.cpp
  ${LLS}/lib/Support/Process.cpp
  ${LLS}/lib/Support/Program.cpp
  ${LLS}/lib/Support/raw_os_ostream.cpp
  ${LLS}/lib/Support/raw_ostream.cpp
  ${LLS}/lib/Support/regcomp.c
  ${LLS}/lib/Support/regerror.c
  ${LLS}/lib/Support/Regex.cpp
  ${LLS}/lib/Support/regexec.c
  ${LLS}/lib/Support/regfree.c
  ${LLS}/lib/Support/regstrlcpy.c
  ${LLS}/lib/Support/Signals.cpp
  ${LLS}/lib/Support/SmallPtrSet.cpp
  ${LLS}/lib/Support/SmallVector.cpp
  ${LLS}/lib/Support/StringExtras.cpp
  ${LLS}/lib/Support/StringMap.cpp
  ${LLS}/lib/Support/StringRef.cpp
  ${LLS}/lib/Support/StringSaver.cpp
  ${LLS}/lib/Support/TargetParser.cpp
  ${LLS}/lib/Support/Threading.cpp
  ${LLS}/lib/Support/Timer.cpp
  ${LLS}/lib/Support/Triple.cpp
  ${LLS}/lib/Support/Twine.cpp
  ${SZ}/src/IceAssemblerARM32.cpp
  ${SZ}/src/IceAssembler.cpp
  ${SZ}/src/IceCfg.cpp
  ${SZ}/src/IceCfgNode.cpp
  ${SZ}/src/IceClFlags.cpp
  ${SZ}/src/IceELFObjectWriter.cpp
  ${SZ}/src/IceELFSection.cpp
  ${SZ}/src/IceFixups.cpp
  ${SZ}/src/IceGlobalContext.cpp
  ${SZ}/src/IceGlobalInits.cpp
  ${SZ}/src/IceInstARM32.cpp
  ${SZ}/src/IceInst.cpp
  ${SZ}/src/IceInstrumentation.cpp
  ${SZ}/src/IceIntrinsics.cpp
  ${SZ}/src/IceLiveness.cpp
  ${SZ}/src/IceLoopAnalyzer.cpp
  ${SZ}/src/IceMangling.cpp
  ${SZ}/src/IceMemory.cpp
  ${SZ}/src/IceOperand.cpp
  ${SZ}/src/IceRangeSpec.cpp
  ${SZ}/src/IceRegAlloc.cpp
  ${SZ}/src/IceRevision.cpp
  ${SZ}/src/IceRNG.cpp
  ${SZ}/src/IceSwitchLowering.cpp
  ${SZ}/src/IceTargetLoweringARM32.cpp
  ${SZ}/src/IceTargetLowering.cpp
  ${SZ}/src/IceThreading.cpp
  ${SZ}/src/IceTimerTree.cpp
  ${SZ}/src/IceTypes.cpp
  ${SZ}/src/IceVariableSplitting.cpp)
add_library(subzero STATIC ${SUBZERO_SRCS})
target_include_directories(subzero PRIVATE ${SUBZERO_INCLUDES})

# ---- swiftshader_top (renderer core, Reactor on Subzero) ----
set(TOP_SRCS
  Common/CPUID.cpp Common/Configurator.cpp Common/DebugAndroid.cpp
  Common/GrallocAndroid.cpp Common/Half.cpp Common/Math.cpp Common/Memory.cpp
  Common/Resource.cpp Common/Socket.cpp Common/Thread.cpp Common/Timer.cpp
  Main/Config.cpp Main/FrameBuffer.cpp Main/FrameBufferAndroid.cpp
  Main/SwiftConfig.cpp
  Reactor/Reactor.cpp Reactor/Debug.cpp Reactor/DebugAndroid.cpp
  Reactor/ExecutableMemory.cpp Reactor/SubzeroReactor.cpp Reactor/Optimizer.cpp
  Renderer/Blitter.cpp Renderer/Clipper.cpp Renderer/Color.cpp
  Renderer/Context.cpp Renderer/ETC_Decoder.cpp Renderer/Matrix.cpp
  Renderer/PixelProcessor.cpp Renderer/Plane.cpp Renderer/Point.cpp
  Renderer/QuadRasterizer.cpp Renderer/Renderer.cpp Renderer/Sampler.cpp
  Renderer/SetupProcessor.cpp Renderer/Surface.cpp Renderer/TextureStage.cpp
  Renderer/Vector.cpp Renderer/VertexProcessor.cpp
  Shader/Constants.cpp Shader/PixelPipeline.cpp Shader/PixelProgram.cpp
  Shader/PixelRoutine.cpp Shader/PixelShader.cpp Shader/SamplerCore.cpp
  Shader/SetupRoutine.cpp Shader/Shader.cpp Shader/ShaderCore.cpp
  Shader/VertexPipeline.cpp Shader/VertexProgram.cpp Shader/VertexRoutine.cpp
  Shader/VertexShader.cpp
  OpenGL/common/Image.cpp OpenGL/common/Object.cpp OpenGL/common/MatrixStack.cpp)
list(TRANSFORM TOP_SRCS PREPEND ${SRC}/)
add_library(swiftshader_top STATIC ${TOP_SRCS})
target_compile_definitions(swiftshader_top PRIVATE LOG_TAG="swiftshader")
target_include_directories(swiftshader_top PRIVATE
  ${SS}/include ${SRC}/OpenGL ${SRC} ${SUBZERO_INCLUDES} ${KK_INCLUDES})

# ---- GLSL compiler ----
set(COMP_SRCS
  preprocessor/DiagnosticsBase.cpp preprocessor/DirectiveHandlerBase.cpp
  preprocessor/DirectiveParser.cpp preprocessor/ExpressionParser.cpp
  preprocessor/Input.cpp preprocessor/Lexer.cpp preprocessor/Macro.cpp
  preprocessor/MacroExpander.cpp preprocessor/Preprocessor.cpp
  preprocessor/Token.cpp preprocessor/Tokenizer.cpp
  AnalyzeCallDepth.cpp Compiler.cpp debug.cpp Diagnostics.cpp
  DirectiveHandler.cpp glslang_lex.cpp glslang_tab.cpp InfoSink.cpp
  Initialize.cpp InitializeParseContext.cpp IntermTraverse.cpp
  Intermediate.cpp intermOut.cpp ossource_posix.cpp OutputASM.cpp
  parseConst.cpp ParseHelper.cpp PoolAlloc.cpp SymbolTable.cpp
  TranslatorASM.cpp util.cpp ValidateLimitations.cpp ValidateSwitch.cpp)
list(TRANSFORM COMP_SRCS PREPEND ${SRC}/OpenGL/compiler/)
add_library(swiftshader_compiler STATIC ${COMP_SRCS})
target_compile_definitions(swiftshader_compiler PRIVATE LOG_TAG="swiftshader_compiler")
set(GL_INCLUDES ${SS}/include ${SRC}/OpenGL ${SRC} ${SRC}/Renderer
  ${SRC}/Common ${SRC}/Shader ${SRC}/Main ${KK_INCLUDES})
target_include_directories(swiftshader_compiler PRIVATE ${GL_INCLUDES})

# ---- device libraries (from the image's /system/lib) ----
set(DEV ${KK}/devlibs)
set(DEVICE_LIBS ${DEV}/libcutils.so ${DEV}/libhardware.so log dl)

function(gl_lib name tag srcdir lds)
  add_library(${name} SHARED ${ARGN})
  target_compile_definitions(${name} PRIVATE LOG_TAG="${tag}"
    EGLAPI= GL_API= GL_APICALL= GL_GLEXT_PROTOTYPES EGL_EGLEXT_PROTOTYPES)
  target_include_directories(${name} PRIVATE ${GL_INCLUDES} ${srcdir})
  target_link_libraries(${name} PRIVATE
    swiftshader_top
    swiftshader_compiler subzero ${DEVICE_LIBS})
  target_link_options(${name} PRIVATE
    -Wl,--version-script=${lds} -Wl,--gc-sections -Wl,--hash-style=sysv
    -Wl,--no-undefined -static-libstdc++)
endfunction()

set(E ${SRC}/OpenGL/libEGL)
gl_lib(EGL_swiftshader libEGL_swiftshader ${E} ${E}/libEGL.lds
  ${E}/Config.cpp ${E}/Display.cpp ${E}/Surface.cpp ${E}/libEGL.cpp
  ${E}/main.cpp ${SRC}/Common/SharedLibrary.cpp)

set(G ${SRC}/OpenGL/libGLESv2)
gl_lib(GLESv2_swiftshader libGLESv2_swiftshader ${G} ${G}/libGLESv2.lds
  ${G}/Buffer.cpp ${G}/Context.cpp ${G}/Device.cpp ${G}/Fence.cpp
  ${G}/Framebuffer.cpp ${G}/IndexDataManager.cpp ${G}/libGLESv2.cpp
  ${G}/libGLESv3.cpp ${G}/main.cpp ${G}/entry_points.cpp ${G}/Program.cpp
  ${G}/Query.cpp ${G}/Renderbuffer.cpp ${G}/ResourceManager.cpp
  ${G}/Shader.cpp ${G}/Texture.cpp ${G}/TransformFeedback.cpp
  ${G}/utilities.cpp ${G}/VertexArray.cpp ${G}/VertexDataManager.cpp
  ${SRC}/Common/SharedLibrary.cpp)

set(C ${SRC}/OpenGL/libGLES_CM)
gl_lib(GLESv1_CM_swiftshader libGLES_CM_swiftshader ${C} ${C}/libGLES_CM.lds
  ${C}/Buffer.cpp ${C}/Context.cpp ${C}/Device.cpp ${C}/Framebuffer.cpp
  ${C}/IndexDataManager.cpp ${C}/libGLES_CM.cpp ${C}/main.cpp
  ${C}/Renderbuffer.cpp ${C}/ResourceManager.cpp ${C}/Texture.cpp
  ${C}/utilities.cpp ${C}/VertexDataManager.cpp ${SRC}/Common/SharedLibrary.cpp)
