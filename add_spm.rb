require 'xcodeproj'

project_path = './FaceDetecting.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Ensure packages list exists
project.root_object.package_references ||= []

# Check if TFLite is already added
unless project.root_object.package_references.any? { |ref| ref.repositoryURL == 'https://github.com/tensorflow/tensorflow-lite-swift.git' }
  package_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package_ref.repositoryURL = 'https://github.com/tensorflow/tensorflow-lite-swift.git'
  
  # Set version requirement (e.g., branch master, or upToNextMajorVersion)
  package_ref.requirement = {
    'kind' => 'branch',
    'branch' => 'master'
  }
  
  project.root_object.package_references << package_ref
  
  # Add package product dependency to the main target
  target = project.targets.first
  
  package_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  package_dep.package = package_ref
  package_dep.product_name = 'TensorFlowLite'
  
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = package_dep
  
  target.frameworks_build_phase.files << build_file
  
  project.save
  puts "Added TensorFlowLiteSwift"
else
  puts "TensorFlowLiteSwift already present"
end
