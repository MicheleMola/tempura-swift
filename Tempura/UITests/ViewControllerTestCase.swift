//
//  ViewControllerTestCase.swift
//  Tempura
//
//  Created by Andrea De Angelis on 22/11/2018.
//

import Foundation
import XCTest
import Tempura

/**
 Test a ViewController and its ViewControllerModellableView embedded in a Container with a specific ViewModel.
 The test will produce a screenshot of the view.
 The screenshots will be located in the directory specified inside the plist with the `UI_TEST_DIR` key.
 After the screenshot is completed, the test will pass.
 The protocol can only be used in a XCTest environment.
 
 The idea is that the view is rendered but the system waits until `isViewReady` returns true to take the snapshot
 and pass to the next test case. `isViewReady` is invoked various times with the view instance. The method should be implemented
 so that it checks possible things that may not be ready yet and return true only when the view is ready to be snapshotted.
 
 Note that this is a protocol as Xcode fails to recognize methods of XCTestCase's subclasses that are written in Swift.
 */

public protocol ViewControllerTestCase {
  associatedtype VC: AnyViewController & UIViewController
  
  /**
   Add new UI tests to be performed
   
   - parameter testCases: a dictionary of test cases and the corresponding view models. Each pair of the array will be used as input for the `configure(vc:for:model:)` method.
   - parameter context: a context used to pass information and control how the view should be rendered
   */
  func uiTest(testCases: [String: VC.V.VM], context: UITests.VCContext<VC>)
  
  /// Retrieves a dictionary containing the scrollable subviews to test.
  /// The snapshot will contain the whole scrollView content.
  ///
  /// - Parameters:
  ///   - viewController: The viewController under test.
  ///           `isViewReady` has already returned `true` at this point.
  ///   - identifier: the test case identifier.
  /// - Returns: A dictionary where the value is the ScrollView instance to snapshot and the key is
  ///            a suffix for the test case identifier.
  func scrollViewsToTest(in viewController: VC, identifier: String) -> [String: UIScrollView]
  
  /**
   Method used to check whether the view is ready for the snapshot
   - parameter view: the view that will be snapshotted
   - parameter identifier: the test case identifier
   */
  func isViewReady(_ view: VC.V, identifier: String) -> Bool
  
  /// used to provide the ViewController to test.
  /// We cannot instantiate it as we cannot require an init in the AnyViewController protocol
  /// otherwise it will require all of the subclasses to have it specified.
  var viewController: VC { get }
  
  /// configure the VC for the specified `testCase`
  /// this is typically used to manually inject the ViewModel to all the children VCs.
  func configure(vc: VC, for testCase: String, model: VC.V.VM)
}


public extension ViewControllerTestCase where Self: XCTestCase {
  func uiTest(testCases: [String: VC.V.VM], context: UITests.VCContext<VC>) {
    let screenSizeDescription: String = "\(UIScreen.main.bounds.size)"
    let descriptions: [String: String] = Dictionary(uniqueKeysWithValues: testCases.keys.map { identifier in
      let description = "\(identifier) \(screenSizeDescription)"
      return (identifier, description)
    })
    let expectations: [String: XCTestExpectation] = descriptions.mapValues { identifier in
      return XCTestExpectation(description: description)
    }

    XCUIDevice.shared.orientation = context.orientation

    DispatchQueue.global().async {
      for (identifier, model) in testCases {
        var contained: VC!
        var container: UIViewController!
        DispatchQueue.main.sync {
          contained = self.viewController
          container = context.container.container(for: contained)
        }

        guard let description = descriptions[identifier] else { continue }

        let isViewReadyClosure: (UIView) -> Bool = { view in
          var isOrientationCorrect = true

          // read again in case some weird code changed it outside the ViewControllerTestCase APIs
          let isViewInPortrait = view.frame.size.height > view.frame.size.width

          if context.orientation.isPortrait {
            isOrientationCorrect = isViewInPortrait
          } else if context.orientation.isLandscape {
            isOrientationCorrect = !isViewInPortrait
          }

          let isReady = isOrientationCorrect && self.typeErasedIsViewReady(view, identifier: identifier)

          return isReady
        }

        let configureClosure: (UIViewController) -> Void = { vc in
          self.typeErasedConfigure(vc, identifier: identifier, model: model)
        }

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        DispatchQueue.main.async {
          UITests.asyncSnapshot(
            view: container.view,
            viewToWaitFor: contained.view,
            description: description,
            configureClosure: configureClosure,
            isViewReadyClosure: isViewReadyClosure,
            shouldRenderSafeArea: context.renderSafeArea) {
            // ScrollViews snapshot
            self.scrollViewsToTest(in: contained, identifier: identifier).forEach { entry in
              UITests.snapshotScrollableContent(entry.value, description: "\(identifier)_scrollable_content \(screenSizeDescription)")
            }
            dispatchGroup.leave()
            expectations[identifier]?.fulfill()
          }
        }

        // wait for the test case to be completed before starting the next one
        dispatchGroup.wait()
      }
    }
    
    self.wait(for: Array(expectations.values), timeout: 100)
  }

  func typeErasedIsViewReady(_ view: UIView, identifier: String) -> Bool {
    guard let view = view as? VC.V else {
      return false
    }
    return self.isViewReady(view, identifier: identifier)
  }

  func typeErasedConfigure(_ vc: UIViewController, identifier: String, model: ViewModel) -> Void {
    guard
      let vc = vc as? VC,
      let model = model as? VC.V.VM
    else {
      return
    }

    self.configure(vc: vc, for: identifier, model: model)
  }
}

public extension ViewControllerTestCase {
  /// The default implementation returns true
  func isViewReady(_ view: VC.V, identifier: String) -> Bool {
    return true
  }

  /// The default implementation sets the model of the root view to nil and then to the given model
  func configure(vc: VC, for testCase: String, model: VC.V.VM) {
    // Reset this to nil so that animation depending on changes of the model should be skipped
    vc.rootView.model = nil
    vc.rootView.model = model
  }

  func uiTest(testCases: [String: VC.V.VM]) {
    let standardContext = UITests.VCContext<VC>()
    self.uiTest(testCases: testCases, context: standardContext)
  }
  
  func scrollViewsToTest(in view: VC, identifier: String) -> [String: UIScrollView] { return [:] }
}

// MARK: Sub types
extension UITests {
  /// Struct that holds some information used to control how the view is rendered
  public struct VCContext<VC: AnyViewController> {
    
    /// the container in which the main view of the VC will be embedded
    public var container: UITests.Container
    
    /// some hooks that can be added to customize the view after its creation
    public var hooks: [UITests.Hook: UITests.HookClosure<VC.V>]
    
    /// the size of the window in which the view will be rendered
    public var screenSize: CGSize
    
    /// the orientation of the view
    public var orientation: UIDeviceOrientation

    /// whether black dimmed rectangles should be rendered showing the safe area insets
    public var renderSafeArea: Bool
    
    public init(container: Container = .none,
                hooks: [UITests.Hook: UITests.HookClosure<VC.V>] = [:],
                screenSize: CGSize = UIScreen.main.bounds.size,
                orientation: UIDeviceOrientation = .portrait,
                renderSafeArea: Bool = false) {
      self.container = container
      self.hooks = hooks
      self.screenSize = screenSize
      self.orientation = orientation
      self.renderSafeArea = renderSafeArea
    }
  }
}
