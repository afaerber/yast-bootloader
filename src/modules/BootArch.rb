# encoding: utf-8

# File:
#      modules/BootArch.ycp
#
# Module:
#      Bootloader installation and configuration
#
# Summary:
#      Module containing specific data for differnt architecturese
#      (as some architectures support multiple bootloaders, some bootloaders
#      support multiple architectures)
#
# Authors:
#      Jiri Srain <jsrain@suse.cz>
#      Olaf Dabrunz <od@suse.de>
#
# $Id$
#
require "yast"

module Yast
  class BootArchClass < Module
    include Yast::Logger

    def main
      textdomain "bootloader"

      Yast.import "Arch"
      Yast.import "Kernel"
      Yast.import "Linuxrc"
      Yast.import "ProductFeatures"
      Yast.import "Stage"
    end

    # Get parameters for the default kernel
    # @param [String] resume string device to resume from (or empty not to set it)
    # @return [String] parameters for default kernel
    def DefaultKernelParams(resume)
      features = ProductFeatures.GetStringFeature(
        "globals",
        "additional_kernel_parameters"
      )
      kernel_cmdline = Kernel.GetCmdLine.dup

      if Arch.i386 || Arch.x86_64 || Arch.aarch64 || Arch.ppc
        ret = kernel_cmdline
        ret << " resume=#{resume}" unless resume.empty?
        ret << " #{features}" unless features.empty?
        ret.gsub!(/(?:\A|\s)splash=\S*/, "")
        ret << " splash=silent quiet showopts"
        return ret
      elsif Arch.s390
        if ENV["TERM"] == "linux"
          termparm = "TERM=linux console=ttyS0 console=ttyS1"
        else
          termparm = "hvc_iucv=8 TERM=dumb"
        end
        parameters = "#{features} #{termparm}"
        parameters << " resume=#{resume}" unless resume.empty?
        return parameters
      else
        log.warn "Default kernel parameters not defined"
        return kernel_cmdline
      end
    end

    # Is Suspend to Disk available?
    # @return true if STD is available
    def ResumeAvailable
      Arch.i386 || Arch.x86_64 || Arch.s390
    end

    publish :function => :DefaultKernelParams, :type => "string (string)"
    publish :function => :ResumeAvailable, :type => "boolean ()"
  end

  BootArch = BootArchClass.new
  BootArch.main
end
